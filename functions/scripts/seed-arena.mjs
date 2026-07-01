// Dev/test seeder for the Arena (Top 3 finalist voting).
//
// Why: a brand-new app has no public Arena fits, so the Today/Week boards are empty
// and you can't exercise voting/commenting with a single account. This writes mock
// public `rateArena` docs (owned by fake `seed-user-*` uids, so they never collide
// with you), marks the Top 3 by AI score as finalists, and lets you Hot Fit / comment
// on them. It can also seed Hot Fit votes onto one of YOUR posted fits.
//
// Auth: uses Application Default Credentials. Easiest path —
//   1) Firebase Console → Project settings → Service accounts → "Generate new private key"
//   2) export GOOGLE_APPLICATION_CREDENTIALS=/abs/path/to/serviceAccount.json
//
// Run from the functions/ directory (so firebase-admin resolves):
//   cd functions
//   node scripts/seed-arena.mjs seed 5          # create 5 public Arena fits + mark Top 3
//   node scripts/seed-arena.mjs votes <fitId> 5 # add 5 Hot Fit votes to a fit
//   node scripts/seed-arena.mjs clean           # delete everything this script created
//
// All seeded docs carry isSeed:true so `clean` removes them (and their votes) cleanly.
// Safe to run against the dev project; do NOT run against production with real users.

import { initializeApp, applicationDefault } from "firebase-admin/app";
import { getFirestore, FieldValue } from "firebase-admin/firestore";

const PROJECT_ID = process.env.GCLOUD_PROJECT || "fitcheck-d3091";
initializeApp({ credential: applicationDefault(), projectId: PROJECT_ID });
const db = getFirestore();

const GOALS = ["professional", "campus", "date_night", "streetwear", "gym"];
const NAMES = ["Chandan", "Alex", "Soham", "Maya", "Priya", "Jordan", "Leo", "Nina"];
const [, , cmd = "seed", arg1, arg2] = process.argv;

// dayId / weekId mirrors of the backend (UTC). Keep byte-identical to
// analyze-outfit.ts so seeded fits land on the same boards the app reads.
function dayId(date = new Date()) {
  const y = date.getUTCFullYear(), m = date.getUTCMonth() + 1, d = date.getUTCDate();
  return `${String(y).padStart(4, "0")}-${String(m).padStart(2, "0")}-${String(d).padStart(2, "0")}`;
}
function weekId(date = new Date()) {
  const d = new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate()));
  const isoDay = d.getUTCDay() === 0 ? 7 : d.getUTCDay();
  d.setUTCDate(d.getUTCDate() + 4 - isoDay);
  const isoYear = d.getUTCFullYear();
  const yearStart = Date.UTC(isoYear, 0, 1);
  const week = Math.ceil(((d.getTime() - yearStart) / 86_400_000 + 1) / 7);
  return `${String(isoYear).padStart(4, "0")}-W${String(week).padStart(2, "0")}`;
}

async function seed() {
  const n = parseInt(arg1 ?? "5", 10);
  const today = dayId(), week = weekId();
  for (let i = 0; i < n; i++) {
    const ref = db.collection("rateArena").doc();
    await ref.set({
      ownerUid: `seed-user-${i + 1}`,
      fitCheckId: ref.id,
      // Stable random photo per fit — looks like a real outfit, no Storage upload needed.
      imageURL: `https://picsum.photos/seed/arena-${ref.id}/600/800`,
      ownerDisplayName: NAMES[i % NAMES.length],
      ownerPhotoURL: null,
      styleGoal: GOALS[i % GOALS.length],
      aiScore: Math.round((7 + Math.random() * 2.5) * 10) / 10,
      hotFitCount: 0,
      voteCount: 0,
      commentCount: 0,
      reportCount: 0,
      dayId: today,
      weekId: week,
      isTodayFinalist: false,
      isWeekFinalist: false,
      todayRank: null,
      weekRank: null,
      status: "live",
      moderation: "approved",
      isDeleted: false,
      isSeed: true,
      createdAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });
    console.log(`✅ seeded rateArena/${ref.id} (${NAMES[i % NAMES.length]}, ${GOALS[i % GOALS.length]})`);
  }
  await recompute(today, week);
  console.log(`\nDone. ${n} public Arena fits created and Top 3 finalists marked. Open the Arena tab.`);
}

// Mark the Top 3 (by AI score) finalists for today's day and this week, mirroring
// recomputeFinalists in arena.ts so the app's boards show the seeded leaders.
async function recompute(day, week) {
  for (const [field, value, flag, rank] of [
    ["dayId", day, "isTodayFinalist", "todayRank"],
    ["weekId", week, "isWeekFinalist", "weekRank"],
  ]) {
    const snap = await db.collection("rateArena").where(field, "==", value).get();
    const eligible = snap.docs
      .filter((d) => {
        const x = d.data();
        return x.status === "live" && x.isDeleted !== true && typeof x.aiScore === "number" && x.aiScore >= 6.5;
      })
      .sort((a, b) => (b.data().aiScore ?? 0) - (a.data().aiScore ?? 0));
    const rankById = new Map(eligible.slice(0, 3).map((d, i) => [d.id, i + 1]));
    const batch = db.batch();
    for (const d of snap.docs) {
      const r = rankById.get(d.id) ?? null;
      batch.update(d.ref, { [flag]: r !== null, [rank]: r, updatedAt: FieldValue.serverTimestamp() });
    }
    await batch.commit();
    console.log(`   ${field}=${value}: top ${rankById.size} marked finalists`);
  }
}

async function seedVotes() {
  const fitId = arg1;
  const n = parseInt(arg2 ?? "5", 10);
  if (!fitId) { console.error("Usage: node scripts/seed-arena.mjs votes <fitId> [n]"); process.exit(1); }
  const ref = db.collection("rateArena").doc(fitId);
  if (!(await ref.get()).exists) { console.error(`rateArena/${fitId} not found. Post a fit to the Arena first.`); process.exit(1); }
  for (let i = 0; i < n; i++) {
    await ref.collection("votes").doc(`seed-voter-${i + 1}`).set(
      { liked: true, createdAt: FieldValue.serverTimestamp(), isSeed: true },
      { merge: true }
    );
  }
  // Recompute the aggregate from the votes subcollection.
  const votes = await ref.collection("votes").get();
  await ref.update({ voteCount: votes.size, hotFitCount: votes.size });
  console.log(`✅ ${fitId} now has ${votes.size} Hot Fit votes.`);
}

async function clean() {
  const snap = await db.collection("rateArena").where("isSeed", "==", true).get();
  for (const doc of snap.docs) {
    const votes = await doc.ref.collection("votes").get();
    await Promise.all(votes.docs.map((v) => v.ref.delete()));
    const comments = await doc.ref.collection("comments").get();
    await Promise.all(comments.docs.map((c) => c.ref.delete()));
    await doc.ref.delete();
    console.log(`🗑️  deleted rateArena/${doc.id} (+${votes.size} votes, ${comments.size} comments)`);
  }
  // Also clear seed votes left on real (non-seed) fits, e.g. from the `votes` command.
  try {
    const real = await db.collectionGroup("votes").where("isSeed", "==", true).get();
    await Promise.all(real.docs.map((v) => v.ref.delete()));
    console.log(`\nDone. Removed ${snap.size} seed fits and ${real.size} stray seed votes.`);
  } catch (e) {
    console.log(`\nDone. Removed ${snap.size} seed fits.`);
    console.log(`(Skipped stray seed-vote sweep: ${e.code || e.message}. Delete those vote docs manually or create the suggested index.)`);
  }
}

const run = { seed, votes: seedVotes, clean }[cmd];
if (!run) { console.error(`Unknown command "${cmd}". Use: seed | votes | clean`); process.exit(1); }
run().then(() => process.exit(0)).catch((e) => { console.error(e); process.exit(1); });
