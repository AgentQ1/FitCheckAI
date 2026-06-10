import * as admin from "firebase-admin";
import { onRequest } from "firebase-functions/v2/https";
import Stripe from "stripe";

let _stripe: Stripe | null = null;
function getStripeWithWebhook(): { stripe: Stripe; webhookSecret: string } {
  const secretKey     = process.env.STRIPE_SECRET_KEY    ?? "";
  const webhookSecret = process.env.STRIPE_WEBHOOK_SECRET ?? "";
  if (!secretKey)     throw new Error("Stripe secret key not configured. Set STRIPE_SECRET_KEY in functions env.");
  if (!webhookSecret) throw new Error("Stripe webhook secret not configured. Set STRIPE_WEBHOOK_SECRET in functions env.");
  if (!_stripe) {
    _stripe = new Stripe(secretKey, { apiVersion: "2023-10-16" });
  }
  return { stripe: _stripe, webhookSecret };
}

// Cold-start visibility for required webhook env vars.
(function logWebhookEnvOnce() {
  const missing = ["STRIPE_SECRET_KEY", "STRIPE_WEBHOOK_SECRET"].filter((k) => !process.env[k]);
  if (missing.length) console.warn(`[stripeWebhook] Missing env vars: ${missing.join(", ")}`);
})();

export const stripeWebhook = onRequest({ timeoutSeconds: 30, invoker: "public" }, async (req, res) => {
  res.set("Access-Control-Allow-Origin", "*");

  if (req.method !== "POST") {
    res.status(405).send("Method Not Allowed");
    return;
  }

  let event: Stripe.Event;
  try {
    const { stripe, webhookSecret } = getStripeWithWebhook();
    const sig = req.headers["stripe-signature"] as string | undefined;
    if (!sig) {
      console.error("[stripeWebhook] Missing stripe-signature header");
      res.status(400).send("Missing stripe-signature header");
      return;
    }
    // Firebase Functions v2 onRequest exposes the raw body as req.rawBody.
    // We must NOT fall back to JSON.stringify(req.body) — that re-serializes
    // with different whitespace and signature verification will always fail.
    const rawBody: Buffer | undefined = (req as any).rawBody;
    if (!rawBody) {
      console.error("[stripeWebhook] req.rawBody missing — cannot verify signature");
      res.status(400).send("Raw body unavailable");
      return;
    }
    event = stripe.webhooks.constructEvent(rawBody, sig, webhookSecret);
  } catch (err: any) {
    console.error("Webhook signature verification failed:", err.message);
    res.status(400).send(`Webhook Error: ${err.message}`);
    return;
  }

  const db = admin.firestore();
  console.log(`[stripeWebhook] Processing event: ${event.type}`);

  try {
    switch (event.type) {

      case "checkout.session.completed": {
        const session = event.data.object as Stripe.Checkout.Session;
        const uid: string = session.metadata?.firebaseUid ?? "";
        const plan: string = session.metadata?.plan ?? "";
        if (!uid) { console.warn("[stripeWebhook] No firebaseUid in session metadata"); break; }

        const subscriptionId = typeof session.subscription === "string"
          ? session.subscription
          : session.subscription?.id ?? "";

        // Pull the priceId for parity with the spec — handy for Stripe-side
        // reconciliation even though the app keys off planName/tier.
        const { stripe } = getStripeWithWebhook();
        let priceId = "";
        try {
          const items = await stripe.checkout.sessions.listLineItems(session.id, { limit: 1 });
          priceId = items.data[0]?.price?.id ?? "";
        } catch (err) {
          console.warn(`[stripeWebhook] listLineItems failed for session=${session.id}: ${(err as Error).message}`);
        }

        // Belt-and-suspenders: flip the user to premium here as well. If the
        // customer.subscription.created event lands later (or never), the iOS
        // app still unlocks the moment this event is delivered.
        const tier = plan === "yearly" ? "yearly" : plan === "student" ? "student" : "monthly";
        const isUnlocked = session.status === "complete" || session.payment_status === "paid" || session.payment_status === "no_payment_required";

        await db.collection("users").doc(uid).set({
          stripeCustomerId:     session.customer as string,
          stripeSubscriptionId: subscriptionId,
          stripePriceId:        priceId || admin.firestore.FieldValue.delete(),
          isPremium:            isUnlocked,
          subscriptionStatus:   isUnlocked ? "active" : (session.status ?? "pending"),
          subscriptionTier:     isUnlocked ? tier : "free",
          planName:             plan,
          fitCheckLimit:        isUnlocked ? 999 : 3,
          premiumGrantedAt:     isUnlocked ? admin.firestore.FieldValue.serverTimestamp() : admin.firestore.FieldValue.delete(),
          updatedAt:            admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });

        // Update payment record
        await db.collection("users").doc(uid)
          .collection("payments").doc(session.id)
          .set({
            stripeCheckoutSessionId: session.id,
            stripePaymentIntentId:   session.payment_intent as string ?? null,
            stripeSubscriptionId:    subscriptionId,
            stripeCustomerId:        session.customer as string,
            stripePriceId:           priceId || null,
            status: "completed",
            planName: plan,
            currency: session.currency,
            amount: session.amount_total,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          }, { merge: true });

        console.log(`[stripeWebhook] checkout.session.completed uid=${uid} isPremium=${isUnlocked} plan=${plan} priceId=${priceId || "?"} subId=${subscriptionId || "?"}`);
        break;
      }

      case "customer.subscription.created":
      case "customer.subscription.updated": {
        const sub = event.data.object as Stripe.Subscription;
        const uid: string = sub.metadata?.firebaseUid ?? "";
        if (!uid) {
          // Try to look up by customerId
          const snap = await db.collection("users")
            .where("stripeCustomerId", "==", sub.customer as string)
            .limit(1).get();
          if (snap.empty) { console.warn("No user for customer:", sub.customer); break; }
          await updateSubscription(db, snap.docs[0].id, sub);
        } else {
          await updateSubscription(db, uid, sub);
        }
        break;
      }

      case "customer.subscription.deleted": {
        const sub = event.data.object as Stripe.Subscription;
        const uid: string = sub.metadata?.firebaseUid ?? "";
        const targetUid = uid || await findUidByCustomer(db, sub.customer as string);
        if (!targetUid) { console.warn(`[stripeWebhook] subscription.deleted: no uid for customer=${sub.customer}`); break; }
        await db.collection("users").doc(targetUid).set({
          isPremium:           false,
          subscriptionStatus:  "canceled",
          subscriptionTier:    "free",
          fitCheckLimit:       3,
          stripeSubscriptionId: sub.id,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
        console.log(`[stripeWebhook] subscription.deleted uid=${targetUid} subId=${sub.id}`);
        break;
      }

      case "invoice.payment_succeeded": {
        const invoice = event.data.object as Stripe.Invoice;
        const sub = invoice.subscription
          ? await getSubscriptionFromInvoice(db, invoice.subscription as string)
          : null;
        if (!sub) {
          console.warn(`[stripeWebhook] invoice.payment_succeeded: no subscription on invoice=${invoice.id}`);
          break;
        }
        const uid: string = sub.metadata?.firebaseUid ?? await findUidByCustomer(db, invoice.customer as string);
        if (!uid) {
          console.warn(`[stripeWebhook] invoice.payment_succeeded: no uid for customer=${invoice.customer}`);
          break;
        }

        // Guard period end — same defensive shape as updateSubscription().
        const periodEndSecs = invoice.lines.data[0]?.period?.end;
        const update: Record<string, unknown> = {
          subscriptionStatus: "active",
          isPremium: true,
          fitCheckLimit: 999,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        };
        if (typeof periodEndSecs === "number" && Number.isFinite(periodEndSecs) && periodEndSecs > 0) {
          update.currentPeriodEnd = admin.firestore.Timestamp.fromDate(new Date(periodEndSecs * 1000));
        }
        await db.collection("users").doc(uid).set(update, { merge: true });
        console.log(`[stripeWebhook] invoice.payment_succeeded uid=${uid} subId=${sub.id} periodEnd=${periodEndSecs ?? "missing"}`);
        break;
      }

      case "invoice.payment_failed": {
        const invoice = event.data.object as Stripe.Invoice;
        const uid = await findUidByCustomer(db, invoice.customer as string);
        if (!uid) {
          console.warn(`[stripeWebhook] invoice.payment_failed: no uid for customer=${invoice.customer}`);
          break;
        }
        // Keep isPremium grace until subscription.deleted fires — Stripe will
        // retry the invoice. past_due is a status the UI can surface.
        await db.collection("users").doc(uid).set({
          subscriptionStatus: "past_due",
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
        console.log(`[stripeWebhook] invoice.payment_failed uid=${uid} invoiceId=${invoice.id}`);
        break;
      }

      default:
        console.log(`[stripeWebhook] Unhandled event type: ${event.type}`);
    }

    res.status(200).json({ received: true });

  } catch (err) {
    console.error("[stripeWebhook] Handler error:", err);
    res.status(500).json({ error: "Webhook handler failed" });
  }
});

async function updateSubscription(
  db: admin.firestore.Firestore,
  uid: string,
  sub: Stripe.Subscription
): Promise<void> {
  const isActive = ["active", "trialing"].includes(sub.status);
  const plan = sub.metadata?.plan ?? inferPlanFromSub(sub);
  const priceId = sub.items.data[0]?.price?.id ?? "";

  // `current_period_end` can be missing on the very first customer.subscription.created
  // event (incomplete subs, or trial subs before Stripe finalizes the period).
  // If it's not a positive integer, skip writing it instead of letting
  // Timestamp.fromDate(new Date(NaN)) throw — that error used to abort the
  // whole handler and is exactly why isPremium never flipped.
  const periodEndSecs = sub.current_period_end;
  const periodEnd =
    typeof periodEndSecs === "number" && Number.isFinite(periodEndSecs) && periodEndSecs > 0
      ? admin.firestore.Timestamp.fromDate(new Date(periodEndSecs * 1000))
      : null;

  const update: Record<string, unknown> = {
    isPremium:           isActive,
    subscriptionStatus:  sub.status,
    subscriptionTier:    isActive ? (plan === "yearly" ? "yearly" : plan === "student" ? "student" : "monthly") : "free",
    stripeSubscriptionId: sub.id,
    stripePriceId:       priceId || admin.firestore.FieldValue.delete(),
    planName:            plan,
    fitCheckLimit:       isActive ? 999 : 3,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  };
  if (periodEnd) update.currentPeriodEnd = periodEnd;
  if (isActive)  update.premiumGrantedAt = admin.firestore.FieldValue.serverTimestamp();

  await db.collection("users").doc(uid).set(update, { merge: true });
  console.log(`[stripeWebhook] updateSubscription uid=${uid} status=${sub.status} isPremium=${isActive} priceId=${priceId || "?"} periodEnd=${periodEndSecs ?? "missing"}`);
}

function inferPlanFromSub(sub: Stripe.Subscription): string {
  const interval = sub.items.data[0]?.plan?.interval;
  return interval === "year" ? "yearly" : "monthly";
}

async function findUidByCustomer(
  db: admin.firestore.Firestore,
  customerId: string
): Promise<string> {
  const snap = await db.collection("users")
    .where("stripeCustomerId", "==", customerId)
    .limit(1).get();
  return snap.empty ? "" : snap.docs[0].id;
}

async function getSubscriptionFromInvoice(
  _db: admin.firestore.Firestore,
  subscriptionId: string
): Promise<Stripe.Subscription | null> {
  try {
    const { stripe } = getStripeWithWebhook();
    return await stripe.subscriptions.retrieve(subscriptionId);
  } catch (err) {
    console.error("[getSubscriptionFromInvoice] retrieve failed:", (err as Error)?.message);
    return null;
  }
}
