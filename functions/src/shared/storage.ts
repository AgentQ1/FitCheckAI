import * as admin from "firebase-admin";
import { randomUUID } from "crypto";

/**
 * A DURABLE (non-expiring) Firebase download URL for a Storage object.
 *
 * Previously the analyze flow stored a 7-day SIGNED URL as the fit's `thumbnailURL`,
 * which the iOS app caches and prefers — so History / analysis-detail images broke
 * once that window elapsed. This returns the same kind of URL the Firebase client
 * SDK's `getDownloadURL()` produces (a `firebasestorage.googleapis.com` URL backed by
 * a download token), which does not expire. It reuses the token the client SDK set at
 * upload time, minting one only if absent. Falls back to a 7-day signed URL if the
 * object metadata can't be read/written, and to null if even that fails — callers
 * keep the durable `storagePath` regardless, so the image is always recoverable.
 */
export async function durableDownloadURL(storagePath: string): Promise<string | null> {
  const bucket = admin.storage().bucket();
  const file = bucket.file(storagePath);
  try {
    const [metadata] = await file.getMetadata();
    const existing = (metadata.metadata?.firebaseStorageDownloadTokens as string | undefined)?.split(",")[0];
    let token = existing;
    if (!token) {
      token = randomUUID();
      await file.setMetadata({ metadata: { firebaseStorageDownloadTokens: token } });
    }
    const encodedPath = encodeURIComponent(storagePath);
    return `https://firebasestorage.googleapis.com/v0/b/${bucket.name}/o/${encodedPath}?alt=media&token=${token}`;
  } catch (e) {
    console.warn("[durableDownloadURL] token URL failed, falling back to signed URL:", (e as Error)?.message);
    try {
      const [url] = await file.getSignedUrl({
        action: "read",
        expires: Date.now() + 7 * 24 * 60 * 60 * 1000,
      });
      return url;
    } catch {
      return null;
    }
  }
}
