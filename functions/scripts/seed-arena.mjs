// Dev/test seeder for the Rate the Fit / Arena queue.
//
// Why: a brand-new app has no public Arena fits, so the queue is empty and you can't
// exercise the swipe/rate/reveal flow with a single account. This writes mock public
// `rateArena` docs (owned by fake `seed-user-*` uids, so they never collide with you),
// letting you rate them 0/5 → 5/5. It can also seed votes onto one of YOUR posted fits
// so you can test the Human Fit Score reveal without 5 real accounts.
//
// Auth: uses Application Default Credentials. Easiest path —
//   1) Firebase Console → Project settings → Service accounts → "Generate new private key"
//   2) export GOOGLE_APPLICATION_CREDENTIALS=/abs/path/to/serviceAccount.json
//
// Run from the functions/ directory (so firebase-admin resolves):
//   cd functions
//   node scripts/seed-arena.mjs seed 5        # create 5 public Arena fits
//   node scripts/seed-arena.mjs votes <fitId> 5   # add 5 votes to YOUR fit (test reveal)
//   node scripts/seed-arena.mjs clean         # delete everything this script created
//
// All seeded docs carry isSeed:true so `clean` removes them (and their votes) cleanly.
// Safe to run against the dev project; do NOT run against production with real users.

import { initializeApp, applicationDefault } from "firebase-admin/app";
import { getFirestore, FieldValue } from "firebase-admin/firestore";

const PROJECT_ID = process.env.GCLOUD_PROJECT || "fitcheck-d3091";
initializeApp({ credential: applicationDefault(), projectId: PROJECT_ID });
const db = getFirestore();

const GOALS = ["professional", "campus", "date_night", "streetwear", "gym"];
const [, , cmd = "seed", arg1, arg2] = process.argv;

async function seed() {
  const n = parseInt(arg1 ?? "5", 10);
  for (let i = 0; i < n; i++) {
    const ref = db.collection("rateArena").doc();
    await ref.set({
      ownerUid: `seed-user-${i + 1}`,
      fitCheckId: ref.id,
      // Stable random photo per fit — looks like a real outfit, no Storage upload needed.
      imageURL: `https://picsum.photos/seed/arena-${ref.id}/600/800`,
      styleGoal: GOALS[i % GOALS.length],
      aiScore: Math.round((7 + Math.random() * 2.5) * 10) / 10,
      upvotes: 0,
      voteCount: 0,
      reportCount: 0,
      status: "live",
      moderation: "approved",
      voteBucket: Math.floor(Math.random() * 1000),
      isSeed: true,
      createdAt: FieldValue.serverTimestamp(),
    });
    console.log(`✅ seeded rateArena/${ref.id} (seed-user-${i + 1}, ${GOALS[i % GOALS.length]})`);
  }
  console.log(`\nDone. ${n} public Arena fits created. Open the Arena tab and rate them.`);
}

async function seedVotes() {
  const fitId = arg1;
  const n = parseInt(arg2 ?? "5", 10);
  if (!fitId) { console.error("Usage: node scripts/seed-arena.mjs votes <fitId> [n]"); process.exit(1); }
  const ref = db.collection("rateArena").doc(fitId);
  if (!(await ref.get()).exists) { console.error(`rateArena/${fitId} not found. Post a fit to the Arena first.`); process.exit(1); }
  for (let i = 0; i < n; i++) {
    await ref.collection("votes").doc(`seed-voter-${i + 1}`).set(
      { liked: Math.random() > 0.25, votedAt: FieldValue.serverTimestamp(), isSeed: true },
      { merge: true }
    );
  }
  // Recompute the aggregate from the votes subcollection.
  const votes = await ref.collection("votes").get();
  const upvotes = votes.docs.filter((d) => d.data().liked === true).length;
  await ref.update({ voteCount: votes.size, upvotes });
  console.log(`✅ ${fitId} now has ${votes.size} votes (${upvotes} 👍). Rate 5 other fits, then open your reveal.`);
}

async function clean() {
  const snap = await db.collection("rateArena").where("isSeed", "==", true).get();
  for (const doc of snap.docs) {
    const votes = await doc.ref.collection("votes").get();
    await Promise.all(votes.docs.map((v) => v.ref.delete()));
    await doc.ref.delete();
    console.log(`🗑️  deleted rateArena/${doc.id} (+${votes.size} votes)`);
  }
  // Also clear seed votes left on real (non-seed) fits, e.g. from the `votes` command.
  // The collection-group query may need an index; if so, skip gracefully.
  try {
    const real = await db.collectionGroup("votes").where("isSeed", "==", true).get();
    await Promise.all(real.docs.map((v) => v.ref.delete()));
    console.log(`\nDone. Removed ${snap.size} seed fits and ${real.size} stray seed votes.`);
  } catch (e) {
    console.log(`\nDone. Removed ${snap.size} seed fits.`);
    console.log(`(Skipped stray seed-vote sweep: ${e.code || e.message}. If you used the 'votes' command, delete those vote docs manually or create the suggested index.)`);
  }
}

const run = { seed, votes: seedVotes, clean }[cmd];
if (!run) { console.error(`Unknown command "${cmd}". Use: seed | votes | clean`); process.exit(1); }
run().then(() => process.exit(0)).catch((e) => { console.error(e); process.exit(1); });
