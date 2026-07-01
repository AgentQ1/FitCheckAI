import { onRequest } from "firebase-functions/v2/https";
import * as admin from "firebase-admin";
import { requireAuth, sendError } from "./shared/auth";

const db = admin.firestore();
const storage = admin.storage();

/** Best-effort delete of every doc returned by a normal collection query. */
async function deleteQuery(
  query: admin.firestore.Query,
  tag: string,
  label: string
): Promise<void> {
  try {
    const snap = await query.get();
    await Promise.allSettled(snap.docs.map((d) => d.ref.delete()));
    console.log(`${tag} deleted ${snap.size} ${label}`);
  } catch (e) {
    console.warn(`${tag} ${label} delete failed (non-fatal):`, (e as Error)?.message);
  }
}

/**
 * Best-effort delete of every doc in a collection GROUP whose `field == value`.
 * Used to erase the user's rows that live scattered across many parent docs
 * (leaderboard rows, comments/votes/reports on other people's fits). Batched to
 * respect Firestore's 500-write limit. Never throws — a missing collection-group
 * index must not abort the account deletion (Auth removal still runs).
 */
async function deleteCollectionGroup(
  group: string,
  field: string,
  value: string,
  tag: string,
  label: string
): Promise<void> {
  try {
    const snap = await db.collectionGroup(group).where(field, "==", value).get();
    const docs = snap.docs;
    for (let i = 0; i < docs.length; i += 400) {
      const batch = db.batch();
      docs.slice(i, i + 400).forEach((d) => batch.delete(d.ref));
      await batch.commit();
    }
    console.log(`${tag} deleted ${docs.length} ${label}`);
  } catch (e) {
    console.warn(`${tag} ${label} (collectionGroup ${group}.${field}) delete failed (non-fatal):`, (e as Error)?.message);
  }
}

export const deleteAccount = onRequest(
  { timeoutSeconds: 120, cors: true, invoker: "public" },
  async (req, res) => {
    if (req.method === "OPTIONS") { res.status(204).send(""); return; }
    if (req.method !== "DELETE" && req.method !== "POST") {
      res.status(405).json({ error: "method_not_allowed" });
      return;
    }

    let uid: string;
    try {
      const auth = await requireAuth(req);
      uid = auth.uid;
    } catch (err) {
      sendError(res, 401, "unauthorized", "Invalid or expired token");
      return;
    }

    const tag = `[deleteAccount] uid=${uid}`;
    console.log(`${tag} starting full deletion`);
    try {
      // 1. Delete all Storage files under users/{uid}/ (outfit photos, avatars).
      const bucket = storage.bucket();
      try {
        const [files] = await bucket.getFiles({ prefix: `users/${uid}/` });
        await Promise.allSettled(files.map((f) => f.delete()));
        console.log(`${tag} deleted ${files.length} storage files`);
      } catch (e) {
        // Non-fatal — continue with Firestore + Auth deletion.
        console.warn(`${tag} storage delete failed (non-fatal):`, (e as Error)?.message);
      }

      // 2. Recursively delete the user document and ALL private subcollections
      //    (fit_checks + nested generated_looks/generatedUpgrades/ratings,
      //    saved_looks, savedUpgrades, generation_jobs, payments, …).
      await db.recursiveDelete(db.collection("users").doc(uid));
      console.log(`${tag} recursiveDelete(users/${uid}) done`);

      // 3. Delete the public profile mirror (displayName/photoURL used by leaderboards).
      await db.collection("publicProfiles").doc(uid).delete().catch(() => {});

      // 4. Delete Apple IAP transaction → uid mappings for this user.
      await deleteQuery(db.collection("appleTransactions").where("uid", "==", uid), tag, "appleTransactions");
      // Any queued (unresolved) Apple notifications keyed by this user's transactions.
      await deleteQuery(db.collection("unresolvedAppleNotifications").where("resolvedUid", "==", uid), tag, "unresolved apple notifications");

      // 5. Remove ALL public / shared PARTICIPATION data so nothing identifiable is
      //    left after Arena / leaderboard activity (Apple privacy + GDPR erasure).
      //    Each step is best-effort + logged so one failure can't abort the deletion.

      // 5a. The user's own Arena posts (top-level rateArena docs). recursiveDelete each
      //     so its votes/comments/reports subcollections are removed too.
      try {
        const ownPosts = await db.collection("rateArena").where("ownerUid", "==", uid).get();
        await Promise.allSettled(ownPosts.docs.map((d) => db.recursiveDelete(d.ref)));
        console.log(`${tag} deleted ${ownPosts.size} owned arena posts`);
      } catch (e) {
        console.warn(`${tag} arena post delete failed (non-fatal):`, (e as Error)?.message);
      }

      // 5b. Leaderboard rows the user occupies on EVERY day/week board
      //     (weeklyTrends/*/users/{uid} + dailyTrends/*/users/{uid}); these carry
      //     displayName + photoURL. The top-level users/{uid} doc is keyed by `uid`
      //     (not `userId`), so it is NOT matched here.
      await deleteCollectionGroup("users", "userId", uid, tag, "leaderboard rows");

      // 5c. Comments the user left on OTHER users' fits (carry commenterName + text).
      await deleteCollectionGroup("comments", "commenterUid", uid, tag, "arena comments");

      // 5d. Hot-Fit votes the user cast on other fits.
      await deleteCollectionGroup("votes", "voterUid", uid, tag, "arena votes");

      // 5e. Reports / blocks the user filed (arena report subcollections + the
      //     top-level moderation queue; both carry reporterUid + free-text reason).
      await deleteCollectionGroup("reports", "reporterUid", uid, tag, "reports filed");

      // 6. Delete Firebase Auth user — this is what actually removes the account.
      await admin.auth().deleteUser(uid);
      console.log(`${tag} ✅ account fully deleted`);

      res.status(200).json({ deleted: true });
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : "Deletion failed";
      console.error(`${tag} ❌ deletion failed:`, msg);
      sendError(res, 500, "deletion_failed", msg);
    }
  }
);
