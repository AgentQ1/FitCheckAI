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

// One-time sanity log on cold start so misconfigured env vars are visible in
// the Cloud Functions logs. We only log presence, never values.
(function logStripeEnvOnce() {
  const required = [
    "STRIPE_SECRET_KEY",
    "STRIPE_MONTHLY_PRICE_ID",
    "STRIPE_YEARLY_PRICE_ID",
  ];
  const missing = required.filter((k) => !process.env[k]);
  if (missing.length) {
    console.warn(`[createCheckoutSession] Missing env vars: ${missing.join(", ")}`);
  }
  if (!process.env.STRIPE_STUDENT_PRICE_ID) {
    console.warn("[createCheckoutSession] STRIPE_STUDENT_PRICE_ID not set — Student tier will be rejected (no silent monthly fallback).");
  }
})();

export const createCheckoutSession = onRequest({ timeoutSeconds: 30, invoker: "public" }, async (req, res) => {
  if (req.method === "OPTIONS") {
    res.set("Access-Control-Allow-Origin", "*")
       .set("Access-Control-Allow-Headers", "authorization, content-type")
       .status(204).send("");
    return;
  }
  res.set("Access-Control-Allow-Origin", "*");

  try {
    const user = await requireAuth(req);
    const { plan } = req.body as { plan?: string };

    if (!plan || !["monthly", "yearly", "student"].includes(plan)) {
      return void sendError(res, 400, "invalid_plan", "plan must be 'monthly', 'yearly', or 'student'");
    }

    const monthlyPriceId = process.env.STRIPE_MONTHLY_PRICE_ID ?? "";
    const yearlyPriceId  = process.env.STRIPE_YEARLY_PRICE_ID  ?? "";
    const studentPriceId = process.env.STRIPE_STUDENT_PRICE_ID ?? "";

    // Resolve price ID per plan. We DO NOT silently bill Student users at the
    // monthly rate any more — if no student price is configured, surface a
    // clean error so the iOS app can hide the Student tier.
    let priceId = "";
    let billingPlan = plan;
    if (plan === "monthly") {
      priceId = monthlyPriceId;
    } else if (plan === "yearly") {
      priceId = yearlyPriceId;
    } else if (plan === "student") {
      if (!studentPriceId) {
        return void sendError(
          res,
          501,
          "student_plan_unavailable",
          "Student pricing isn't available yet. Please choose Monthly or Yearly."
        );
      }
      priceId = studentPriceId;
    }

    if (!priceId) {
      console.error(`[createCheckoutSession] price_not_configured plan=${plan} monthly=${!!monthlyPriceId} yearly=${!!yearlyPriceId}`);
      return void sendError(res, 500, "price_not_configured", "Subscription pricing isn't configured on the server. Please try again later.");
    }

    const stripe = getStripe();
    const db = admin.firestore();
    const userRef = db.collection("users").doc(user.uid);
    const userSnap = await userRef.get();
    const userData = userSnap.data() ?? {};

    // Create or reuse Stripe customer
    let customerId: string = userData.stripeCustomerId ?? "";
    if (!customerId) {
      const customer = await stripe.customers.create({
        email: user.email || undefined,
        metadata: { firebaseUid: user.uid },
      });
      customerId = customer.id;
      await userRef.update({ stripeCustomerId: customerId });
    }

    const session = await stripe.checkout.sessions.create({
      customer: customerId,
      mode: "subscription",
      payment_method_types: ["card"],
      line_items: [{ price: priceId, quantity: 1 }],
      subscription_data: {
        trial_period_days: 3,
        metadata: { firebaseUid: user.uid, plan, billingPlan },
      },
      success_url: "fitcheckai://stripe/success?session_id={CHECKOUT_SESSION_ID}",
      cancel_url:  "fitcheckai://stripe/cancel",
      metadata: { firebaseUid: user.uid, plan, billingPlan },
    });

    console.log(`[createCheckoutSession] created uid=${user.uid} plan=${plan} priceId=${priceId} sessionId=${session.id} customerId=${customerId}`);

    // Store pending payment record
    await db.collection("users").doc(user.uid)
      .collection("payments").doc(session.id)
      .set({
        stripeCheckoutSessionId: session.id,
        stripeCustomerId: customerId,
        planName: plan,
        status: "pending",
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });

    res.status(200).json({ url: session.url });

  } catch (err) {
    if (err instanceof AuthError) return void sendError(res, err.status, err.code, err.message);
    console.error("createCheckoutSession error:", (err as Error)?.message, err);
    const userMsg = (err as Error)?.message?.includes("not configured")
      ? (err as Error).message
      : "Failed to start checkout. Please try again.";
    sendError(res, 500, "server_error", userMsg);
  }
});
