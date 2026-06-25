import { onRequest } from "firebase-functions/v2/https";
import * as admin from "firebase-admin";
import { requireAuth, sendError } from "./shared/auth";

const db = admin.firestore();

/** Map a query snapshot to plain `{ id, ...data }` rows for the export payload. */
function rows(snap: admin.firestore.QuerySnapshot): Array<Record<string, unknown>> {
  return snap.docs.map((d) => ({ id: d.id, ...d.data() }));
}

/**
 * Authoritative, complete export of ALL data this user owns — private AND public.
 * Mirrors what deleteAccount removes, so a user can see exactly what we hold:
 *   - profile + public profile mirror
 *   - fit checks (+ each fit's generated AI upgrades)
 *   - saved looks + durable saved upgrades
 *   - public Arena posts they own + comments they authored
 *   - their leaderboard standings (daily + weekly)
 */
export const exportUserData = onRequest(
  { timeoutSeconds: 120, cors: true, invoker: "public" },
  async (req, res) => {
    if (req.method === "OPTIONS") { res.status(204).send(""); return; }
    if (req.method !== "GET" && req.method !== "POST") {
      res.status(405).json({ error: "method_not_allowed" });
      return;
    }

    let uid: string;
    try {
      uid = (await requireAuth(req)).uid;
    } catch (err) {
      sendError(res, 401, "unauthorized", "Invalid or expired token");
      return;
    }

    try {
      const userRef = db.collection("users").doc(uid);

      // Top-level reads in parallel.
      const [userSnap, publicSnap, fitSnap, savedSnap, savedUpgradesSnap] = await Promise.all([
        userRef.get(),
        db.collection("publicProfiles").doc(uid).get(),
        userRef.collection("fit_checks").get(),
        userRef.collection("saved_looks").get(),
        userRef.collection("savedUpgrades").get(),
      ]);

      const profile = userSnap.exists ? userSnap.data() : {};
      const publicProfile = publicSnap.exists ? publicSnap.data() : null;

      // Each fit's AI-generated upgrade history (subcollection), fetched concurrently
      // in chunks so a large history doesn't open hundreds of reads at once.
      const fitDocs = fitSnap.docs;
      const fitChecks: Array<Record<string, unknown>> = [];
      for (let i = 0; i < fitDocs.length; i += 20) {
        const chunk = fitDocs.slice(i, i + 20);
        const withUpgrades = await Promise.all(chunk.map(async (doc) => {
          const upgradesSnap = await doc.ref.collection("generatedUpgrades").get().catch(() => null);
          return {
            id: doc.id,
            ...doc.data(),
            generatedUpgrades: upgradesSnap ? rows(upgradesSnap) : [],
          };
        }));
        fitChecks.push(...withUpgrades);
      }

      // Public / shared participation data the user owns. The "users" collection group
      // captures BOTH daily and weekly leaderboard rows (weeklyTrends/*/users +
      // dailyTrends/*/users), which carry userId; the top-level users doc is keyed by
      // `uid` (not `userId`) so it isn't matched.
      const [arenaPostsSnap, arenaCommentsSnap, standingsSnap] = await Promise.all([
        db.collection("rateArena").where("ownerUid", "==", uid).get().catch(() => null),
        db.collectionGroup("comments").where("commenterUid", "==", uid).get().catch(() => null),
        db.collectionGroup("users").where("userId", "==", uid).get().catch(() => null),
      ]);

      const savedLooks = rows(savedSnap);
      const savedUpgrades = rows(savedUpgradesSnap);
      const arenaPosts = arenaPostsSnap ? rows(arenaPostsSnap) : [];
      const arenaComments = arenaCommentsSnap ? rows(arenaCommentsSnap) : [];
      const leaderboardStandings = standingsSnap ? rows(standingsSnap) : [];

      const exportPayload = {
        exportedAt: new Date().toISOString(),
        profile,
        publicProfile,
        fitChecks,
        savedLooks,
        savedUpgrades,
        arenaPosts,
        arenaComments,
        leaderboardStandings,
        meta: {
          totalFitChecks: fitChecks.length,
          totalSavedLooks: savedLooks.length,
          totalSavedUpgrades: savedUpgrades.length,
          totalArenaPosts: arenaPosts.length,
          totalArenaComments: arenaComments.length,
          totalLeaderboardStandings: leaderboardStandings.length,
        },
      };

      console.log(`[exportUserData] uid=${uid} fits=${fitChecks.length} saved=${savedLooks.length} arenaPosts=${arenaPosts.length} comments=${arenaComments.length} standings=${leaderboardStandings.length}`);
      res.status(200).json(exportPayload);
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : "Export failed";
      console.error(`[exportUserData] uid=${uid} failed:`, msg);
      sendError(res, 500, "export_failed", msg);
    }
  }
);
