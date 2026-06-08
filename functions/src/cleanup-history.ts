import * as admin from "firebase-admin";
import { onSchedule } from "firebase-functions/v2/scheduler";

/**
 * Daily server-side safety net for history/upgrade storage growth. The iOS client
 * already prunes after each check / upgrade / History open, but a scheduled sweep
 * guarantees cleanup for users who haven't opened the app and catches anything the
 * client missed.
 *
 * Mirrors the client rules (keep the analyses ARE the `fit_checks` docs — analysisId
 * == fitCheckID):
 *   • keep the newest MAX_HISTORY_ITEMS analyses per user; delete the rest
 *   • keep the newest MAX_GENERATED_UPGRADES upgrades per kept analysis
 *   • UNSAVED generated-upgrade images are deleted from Storage; SAVED ones (and the
 *     top-level `savedUpgrades` collection) are always preserved
 *   • a deleted analysis also loses its original uploaded photo from Storage
 *
 * Keep these in sync with Swift `Config.maxHistoryItems` / `Config.maxGeneratedUpgrades`.
 */
const MAX_HISTORY_ITEMS = 10;
const MAX_GENERATED_UPGRADES = 10;

const TAG = "[cleanupHistory]";

export const cleanupHistory = onSchedule(
  { schedule: "every day 03:00", timeZone: "Etc/UTC", timeoutSeconds: 540, memory: "512MiB" },
  async () => {
    const db = admin.firestore();
    const bucket = admin.storage().bucket();

    const usersSnap = await db.collection("users").get();
    console.log(`${TAG} ▶️ scanning users=${usersSnap.size}`);

    let analysesDeleted = 0;
    let upgradesDeleted = 0;
    let storageDeleted = 0;

    for (const userDoc of usersSnap.docs) {
      const uid = userDoc.id;
      try {
        const fcSnap = await db
          .collection("users").doc(uid)
          .collection("fit_checks")
          .orderBy("createdAt", "desc")
          .get();
        const docs = fcSnap.docs;
        if (docs.length === 0) continue;

        // 1) Delete analyses beyond the newest cap (doc + subcollection + Storage).
        for (const doc of docs.slice(MAX_HISTORY_ITEMS)) {
          const r = await deleteAnalysisCompletely(db, bucket, uid, doc.id, doc.data());
          analysesDeleted += 1;
          upgradesDeleted += r.upgrades;
          storageDeleted += r.storage;
        }

        // 2) Prune the upgrade history of each KEPT analysis to its cap.
        for (const doc of docs.slice(0, MAX_HISTORY_ITEMS)) {
          const r = await pruneGeneratedUpgrades(db, bucket, uid, doc.id);
          upgradesDeleted += r.upgrades;
          storageDeleted += r.storage;
        }
      } catch (err) {
        console.error(`${TAG} ⚠️ user=${uid} cleanup failed:`, (err as Error)?.message);
      }
    }

    console.log(
      `${TAG} 🏁 done — analysesDeleted=${analysesDeleted} ` +
      `generatedUpgradesDeleted=${upgradesDeleted} storageFilesDeleted=${storageDeleted}`
    );
  }
);

/** Best-effort Storage delete that never throws (missing files are fine). */
async function deleteStorageFile(
  bucket: ReturnType<ReturnType<typeof admin.storage>["bucket"]>,
  path: string
): Promise<boolean> {
  try {
    await bucket.file(path).delete({ ignoreNotFound: true });
    return true;
  } catch (err) {
    console.warn(`${TAG} storage delete failed ${path}:`, (err as Error)?.message);
    return false;
  }
}

/**
 * Deletes one analysis entirely: its generatedUpgrades subcollection (UNSAVED images
 * + every subdoc), its original uploaded photo, then the analysis document.
 */
async function deleteAnalysisCompletely(
  db: admin.firestore.Firestore,
  bucket: ReturnType<ReturnType<typeof admin.storage>["bucket"]>,
  uid: string,
  analysisId: string,
  data: admin.firestore.DocumentData
): Promise<{ upgrades: number; storage: number }> {
  let upgrades = 0;
  let storage = 0;

  const subSnap = await db
    .collection("users").doc(uid)
    .collection("fit_checks").doc(analysisId)
    .collection("generatedUpgrades")
    .get();

  for (const d of subSnap.docs) {
    const sd = d.data();
    const saved = sd.isSaved === true;
    // Preserve the Storage image of saved upgrades — savedUpgrades references it.
    if (!saved && typeof sd.imageStoragePath === "string" && sd.imageStoragePath) {
      if (await deleteStorageFile(bucket, sd.imageStoragePath)) storage += 1;
    }
    await d.ref.delete();
    upgrades += 1;
  }

  if (typeof data.storagePath === "string" && data.storagePath) {
    if (await deleteStorageFile(bucket, data.storagePath)) storage += 1;
  }

  await db.collection("users").doc(uid).collection("fit_checks").doc(analysisId).delete();
  console.log(`${TAG} 🗑️ deleted analysisId=${analysisId} uid=${uid} upgrades=${upgrades} storage=${storage}`);
  return { upgrades, storage };
}

/**
 * Keeps the newest MAX_GENERATED_UPGRADES upgrades for an analysis and deletes older
 * UNSAVED ones (doc + Storage file). Saved upgrades are always preserved.
 */
async function pruneGeneratedUpgrades(
  db: admin.firestore.Firestore,
  bucket: ReturnType<ReturnType<typeof admin.storage>["bucket"]>,
  uid: string,
  analysisId: string
): Promise<{ upgrades: number; storage: number }> {
  let upgrades = 0;
  let storage = 0;

  const snap = await db
    .collection("users").doc(uid)
    .collection("fit_checks").doc(analysisId)
    .collection("generatedUpgrades")
    .orderBy("createdAt", "desc")
    .get();

  if (snap.docs.length <= MAX_GENERATED_UPGRADES) return { upgrades, storage };

  for (const d of snap.docs.slice(MAX_GENERATED_UPGRADES)) {
    const sd = d.data();
    if (sd.isSaved === true) continue; // never prune saved
    if (typeof sd.imageStoragePath === "string" && sd.imageStoragePath) {
      if (await deleteStorageFile(bucket, sd.imageStoragePath)) storage += 1;
    }
    await d.ref.delete();
    upgrades += 1;
  }

  if (upgrades > 0) {
    console.log(`${TAG} 🧹 pruned upgrades analysisId=${analysisId} uid=${uid} deleted=${upgrades} storage=${storage}`);
  }
  return { upgrades, storage };
}
