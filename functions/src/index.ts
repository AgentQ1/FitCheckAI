import * as admin from "firebase-admin";

// Initialize Firebase Admin once
if (!admin.apps.length) {
  admin.initializeApp();
}

export { uploadOutfit }         from "./upload-outfit";
export { analyzeOutfit }        from "./analyze-outfit";
export { generateLookOptions }  from "./generate-look-options";
export { generatePreviewUpgrade } from "./generate-preview-upgrade";
export { generateGeminiUpgrade }  from "./generate-gemini-upgrade";
export { generationStatus }     from "./generation-status";
export { saveLook }             from "./save-look";
export { likeLook }             from "./like-look";
export { deleteOutfit }         from "./delete-outfit";
export { generateWeeklyTrend }  from "./weekly-trends";
export { deleteAccount }              from "./delete-account";
export { exportUserData }             from "./export-user-data";
export { rateOutfit }                 from "./rate-outfit";
// Apple In-App Purchase (StoreKit 2) — verification + lifecycle notifications
export { syncAppleSubscription }      from "./sync-apple-subscription";
export { appStoreNotifications }      from "./app-store-notifications";
export { cleanupHistory }             from "./cleanup-history";
// Arena — Top 3 finalist voting (automatic, trend-pool entry)
export { getArenaFinalists }          from "./arena";
export { ensureArenaEntry }           from "./arena";
export { voteHotFit }                 from "./arena";
export { postArenaComment }           from "./arena";
export { getArenaComments }           from "./arena";
export { reportFit }                  from "./arena";
export { recomputeArenaFinalists }    from "./arena";
export { scheduledArenaRecompute }    from "./arena";
