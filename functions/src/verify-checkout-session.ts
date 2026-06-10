import * as admin from "firebase-admin";
import { onRequest } from "firebase-functions/v2/https";
import Stripe from "stripe";
import { requireAuth, sendError, AuthError } from "./shared/auth";

let _stripe: Stripe | null = null;
function getStripe(): Stripe {
  if (_stripe) return _stripe;
  const secretKey = process.env.STRIPE_SECRET_KEY ?? "";
  if (!secretKey) throw new Error("Stripe secret key not configured. Set STRIPE_SECRET_KEY in functions env.");
  _stripe = new Stripe(secretKey, { apiVersion: "2023-10-16" });
  return _stripe;
}

(function logVerifyEnvOnce() {
  if (!process.env.STRIPE_SECRET_KEY) {
    console.warn("[verifyCheckoutSession] Missing env var: STRIPE_SECRET_KEY");
  }
})();

// Called by the iOS app after Stripe Checkout redirects back via deep link.
// The webhook is the authoritative path, but this endpoint exists so the user
// never sits on "Confirming payment…" forever if the webhook is delayed,
// misconfigured, or its event hasn't landed yet. It's idempotent — calling it
// after the webhook already ran just re-asserts the same state.
export const verifyCheckoutSession = onRequest({ timeoutSeconds: 20, invoker: "public" }, async (req, res) => {
  if (req.method === "OPTIONS") {
    res.set("Access-Control-Allow-Origin", "*")
       .set("Access-Control-Allow-Headers", "authorization, content-type")
       .status(204).send("");
    return;
  }
  res.set("Access-Control-Allow-Origin", "*");

  try {
    const user = await requireAuth(req);
    const { sessionId } = (req.body ?? {}) as { sessionId?: string };
    if (!sessionId || !sessionId.startsWith("cs_")) {
      return void sendError(res, 400, "invalid_session_id", "sessionId is required and must be a Stripe Checkout Session ID.");
    }

    const stripe = getStripe();
    const session = await stripe.checkout.sessions.retrieve(sessionId, {
      expand: ["subscription", "customer"],
    });

    const sessionUid = session.metadata?.firebaseUid ?? "";
    if (sessionUid && sessionUid !== user.uid) {
      console.warn(`[verifyCheckoutSession] uid mismatch session=${sessionUid} caller=${user.uid}`);
      return void sendError(res, 403, "forbidden", "This checkout session does not belong to the authenticated user.");
    }

    const customerId =
      typeof session.customer === "string" ? session.customer : session.customer?.id ?? "";

    const subscription =
      typeof session.subscription === "string"
        ? await stripe.subscriptions.retrieve(session.subscription)
        : (session.subscription as Stripe.Subscription | null);

    const subStatus = subscription?.status ?? "";
    const isActive = ["active", "trialing"].includes(subStatus);
    const plan: string =
      (session.metadata?.plan as string) ||
      (subscription?.metadata?.plan as string) ||
      inferPlanFromSub(subscription) ||
      "monthly";

    const tier = !isActive ? "free" : plan === "yearly" ? "yearly" : plan === "student" ? "student" : "monthly";
    const periodEndSecs = subscription?.current_period_end;
    const periodEnd =
      typeof periodEndSecs === "number" && Number.isFinite(periodEndSecs) && periodEndSecs > 0
        ? admin.firestore.Timestamp.fromDate(new Date(periodEndSecs * 1000))
        : null;
    const priceId = subscription?.items.data[0]?.price?.id ?? "";

    const db = admin.firestore();
    const userRef = db.collection("users").doc(user.uid);

    // Idempotent write — mirrors what stripe-webhook.ts writes so the user
    // doc reaches the same state whether the webhook or this verify hit first.
    const updates: Record<string, unknown> = {
      isPremium:           isActive,
      subscriptionStatus:  subStatus || (session.status === "complete" ? "active" : "pending"),
      subscriptionTier:    tier,
      planName:            plan,
      stripeCustomerId:    customerId || admin.firestore.FieldValue.delete(),
      stripeSubscriptionId: subscription?.id ?? null,
      stripePriceId:       priceId || admin.firestore.FieldValue.delete(),
      fitCheckLimit:       isActive ? 999 : 3,
      updatedAt:           admin.firestore.FieldValue.serverTimestamp(),
    };
    if (isActive) {
      updates.premiumGrantedAt = admin.firestore.FieldValue.serverTimestamp();
    }
    if (periodEnd) {
      updates.currentPeriodEnd = periodEnd;
    }
    if (!customerId) delete updates.stripeCustomerId;

    await userRef.set(updates, { merge: true });

    // Update the pending payment record created by createCheckoutSession
    await db.collection("users").doc(user.uid)
      .collection("payments").doc(session.id)
      .set({
        stripeCheckoutSessionId: session.id,
        stripePaymentIntentId:   (session.payment_intent as string) ?? null,
        stripeSubscriptionId:    subscription?.id ?? null,
        stripeCustomerId:        customerId || null,
        status:                  session.status === "complete" ? "completed" : (session.status ?? "unknown"),
        paymentStatus:           session.payment_status ?? null,
        planName:                plan,
        currency:                session.currency ?? null,
        amount:                  session.amount_total ?? null,
        verifiedViaApp:          true,
        updatedAt:               admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });

    console.log(
      `[verifyCheckoutSession] uid=${user.uid} sessionStatus=${session.status} subStatus=${subStatus} isPremium=${isActive}`
    );

    res.status(200).json({
      isPremium:          isActive,
      subscriptionStatus: subStatus || session.status || "unknown",
      subscriptionTier:   tier,
      planName:           plan,
      sessionStatus:      session.status,
      paymentStatus:      session.payment_status,
    });

  } catch (err) {
    if (err instanceof AuthError) return void sendError(res, err.status, err.code, err.message);
    const msg = (err as Error)?.message ?? "";
    console.error("[verifyCheckoutSession] error:", msg, err);
    if (msg.includes("No such checkout.session")) {
      return void sendError(res, 404, "session_not_found", "Checkout session not found.");
    }
    sendError(res, 500, "server_error", "Could not verify checkout session. Please try again.");
  }
});

function inferPlanFromSub(sub: Stripe.Subscription | null | undefined): string {
  if (!sub) return "";
  const interval = sub.items.data[0]?.plan?.interval;
  return interval === "year" ? "yearly" : "monthly";
}
