import * as admin from "firebase-admin";
import { onRequest } from "firebase-functions/v2/https";
import Stripe from "stripe";

function getStripeWithWebhook(): { stripe: Stripe; webhookSecret: string } {
  const secretKey     = process.env.STRIPE_SECRET_KEY    ?? "";
  const webhookSecret = process.env.STRIPE_WEBHOOK_SECRET ?? "";
  if (!secretKey)     throw new Error("Stripe secret key not configured. Set STRIPE_SECRET_KEY in functions env.");
  if (!webhookSecret) throw new Error("Stripe webhook secret not configured. Set STRIPE_WEBHOOK_SECRET in functions env.");
  return {
    stripe: new Stripe(secretKey, { apiVersion: "2023-10-16" }),
    webhookSecret,
  };
}

export const stripeWebhook = onRequest({ timeoutSeconds: 30 }, async (req, res) => {
  res.set("Access-Control-Allow-Origin", "*");

  if (req.method !== "POST") {
    res.status(405).send("Method Not Allowed");
    return;
  }

  let event: Stripe.Event;
  try {
    const { stripe, webhookSecret } = getStripeWithWebhook();
    const sig = req.headers["stripe-signature"] as string;
    // Firebase Functions v2 provides the raw body as req.rawBody
    const rawBody: Buffer = (req as any).rawBody ?? Buffer.from(JSON.stringify(req.body));
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
        if (!uid) { console.warn("No firebaseUid in session metadata"); break; }

        const subscriptionId = typeof session.subscription === "string"
          ? session.subscription
          : session.subscription?.id ?? "";

        await db.collection("users").doc(uid).update({
          stripeCustomerId:   session.customer as string,
          stripeSubscriptionId: subscriptionId,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });

        // Update payment record
        await db.collection("users").doc(uid)
          .collection("payments").doc(session.id)
          .set({
            stripeCheckoutSessionId: session.id,
            stripePaymentIntentId:   session.payment_intent as string ?? null,
            stripeSubscriptionId:    subscriptionId,
            stripeCustomerId:        session.customer as string,
            status: "completed",
            planName: plan,
            currency: session.currency,
            amount: session.amount_total,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          }, { merge: true });

        console.log(`[stripeWebhook] checkout.session.completed uid=${uid}`);
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
        if (!targetUid) { console.warn("No uid for deleted subscription"); break; }
        await db.collection("users").doc(targetUid).update({
          isPremium:           false,
          subscriptionStatus:  "canceled",
          subscriptionTier:    "free",
          stripeSubscriptionId: sub.id,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        console.log(`[stripeWebhook] subscription deleted uid=${targetUid}`);
        break;
      }

      case "invoice.payment_succeeded": {
        const invoice = event.data.object as Stripe.Invoice;
        const sub = invoice.subscription
          ? await getSubscriptionFromInvoice(db, invoice.subscription as string)
          : null;
        if (!sub) break;
        const uid: string = sub.metadata?.firebaseUid ?? await findUidByCustomer(db, invoice.customer as string);
        if (!uid) break;
        const periodEnd = new Date((invoice.lines.data[0]?.period?.end ?? 0) * 1000);
        await db.collection("users").doc(uid).update({
          currentPeriodEnd: admin.firestore.Timestamp.fromDate(periodEnd),
          subscriptionStatus: "active",
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        console.log(`[stripeWebhook] invoice.payment_succeeded uid=${uid}`);
        break;
      }

      case "invoice.payment_failed": {
        const invoice = event.data.object as Stripe.Invoice;
        const uid = await findUidByCustomer(db, invoice.customer as string);
        if (!uid) break;
        await db.collection("users").doc(uid).update({
          subscriptionStatus: "past_due",
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        console.log(`[stripeWebhook] invoice.payment_failed uid=${uid}`);
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
  const periodEnd = new Date(sub.current_period_end * 1000);
  const plan = sub.metadata?.plan ?? inferPlanFromSub(sub);

  await db.collection("users").doc(uid).update({
    isPremium:           isActive,
    subscriptionStatus:  sub.status,
    subscriptionTier:    isActive ? (plan === "yearly" ? "yearly" : "monthly") : "free",
    stripeSubscriptionId: sub.id,
    currentPeriodEnd:    admin.firestore.Timestamp.fromDate(periodEnd),
    planName:            plan,
    fitCheckLimit:       isActive ? 999 : 3,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
  });
  console.log(`[stripeWebhook] updateSubscription uid=${uid} status=${sub.status} isPremium=${isActive}`);
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
  db: admin.firestore.Firestore,
  subscriptionId: string
): Promise<Stripe.Subscription | null> {
  const secretKey = process.env.STRIPE_SECRET_KEY ?? "";
  if (!secretKey) {
    console.error("[getSubscriptionFromInvoice] STRIPE_SECRET_KEY not set");
    return null;
  }
  const stripe = new Stripe(secretKey, { apiVersion: "2023-10-16" });
  try {
    return await stripe.subscriptions.retrieve(subscriptionId);
  } catch (err) {
    console.error("[getSubscriptionFromInvoice] retrieve failed:", (err as Error)?.message);
    return null;
  }
}
