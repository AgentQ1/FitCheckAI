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

      // 2. Delete Firestore subcollections
      const subcollections = ["fit_checks", "saved_looks", "generation_jobs"];
      for (const col of subcollections) {
        const snap = await db.collection(`users/${uid}/${col}`).get();
        if (!snap.empty) {
          const batches: admin.firestore.WriteBatch[] = [];
          let batch = db.batch();
          let count = 0;
          for (const doc of snap.docs) {
            batch.delete(doc.ref);
            count++;
            if (count === 500) {
              batches.push(batch);
              batch = db.batch();
              count = 0;
            }
          }
          if (count > 0) batches.push(batch);
          await Promise.all(batches.map((b) => b.commit()));
        }
      }

      // 3. Delete user document
      await db.collection("users").doc(uid).delete();

      // 4. Delete Firebase Auth user
      await admin.auth().deleteUser(uid);

      res.status(200).json({ deleted: true });
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : "Deletion failed";
      sendError(res, 500, "deletion_failed", msg);
    }
  }
);
