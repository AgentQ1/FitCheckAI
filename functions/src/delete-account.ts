import { onRequest } from "firebase-functions/v2/https";
import * as admin from "firebase-admin";
import { requireAuth, sendError } from "./shared/auth";

const db = admin.firestore();
const storage = admin.storage();

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

    try {
      // 1. Delete all Storage files under users/{uid}/
      const bucket = storage.bucket();
      try {
        const [files] = await bucket.getFiles({ prefix: `users/${uid}/` });
        await Promise.allSettled(files.map((f) => f.delete()));
      } catch {
        // Storage deletion failure is non-fatal — continue with Firestore + Auth deletion
      }

      // 2. Recursively delete the user document and ALL subcollections
      //    (fit_checks + nested generated_looks/generatedUpgrades/ratings,
      //    saved_looks, savedUpgrades, generation_jobs, payments, …).
      await db.recursiveDelete(db.collection("users").doc(uid));

      // 3. Delete the public leaderboard mirror.
      await db.collection("publicProfiles").doc(uid).delete().catch(() => {});

      // 4. Delete Apple IAP transaction → uid mappings for this user.
      try {
        const mappings = await db.collection("appleTransactions").where("uid", "==", uid).get();
        await Promise.allSettled(mappings.docs.map((d) => d.ref.delete()));
      } catch {
        // Non-fatal — orphaned mapping rows are inert and reference a deleted uid.
      }

      // 5. Delete Firebase Auth user
      await admin.auth().deleteUser(uid);

      res.status(200).json({ deleted: true });
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : "Deletion failed";
      sendError(res, 500, "deletion_failed", msg);
    }
  }
);
