import * as admin from "firebase-admin";

// Initialize Firebase Admin once
if (!admin.apps.length) {
  admin.initializeApp();
}

export { uploadOutfit }         from "./upload-outfit";
export { analyzeOutfit }        from "./analyze-outfit";
export { generateLookOptions }  from "./generate-look-options";
export { generatePreviewUpgrade } from "./generate-preview-upgrade";
export { generationStatus }     from "./generation-status";
export { saveLook }             from "./save-look";
export { likeLook }             from "./like-look";
export { deleteOutfit }         from "./delete-outfit";
export { generateWeeklyTrend }  from "./weekly-trends";
export { deleteAccount }              from "./delete-account";
export { exportUserData }             from "./export-user-data";
export { rateOutfit }                 from "./rate-outfit";
export { createCheckoutSession }      from "./create-checkout-session";
export { verifyCheckoutSession }      from "./verify-checkout-session";
export { stripeWebhook }              from "./stripe-webhook";
export { createBillingPortalSession } from "./create-billing-portal-session";
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
