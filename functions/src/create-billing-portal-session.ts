import * as admin from "firebase-admin";
import { onRequest } from "firebase-functions/v2/https";
import Stripe from "stripe";
import { requireAuth, sendError, AuthError } from "./shared/auth";

function getStripe(): Stripe {
  const secretKey = process.env.STRIPE_SECRET_KEY ?? "";
  if (!secretKey) throw new Error("Stripe secret key not configured. Set STRIPE_SECRET_KEY in functions env.");
  return new Stripe(secretKey, { apiVersion: "2023-10-16" });
}

export const createBillingPortalSession = onRequest({ timeoutSeconds: 30 }, async (req, res) => {
  if (req.method === "OPTIONS") {
    res.set("Access-Control-Allow-Origin", "*")
       .set("Access-Control-Allow-Headers", "authorization, content-type")
       .status(204).send("");
    return;
  }
  res.set("Access-Control-Allow-Origin", "*");

  try {
    const user = await requireAuth(req);
    const db = admin.firestore();
    const userSnap = await db.collection("users").doc(user.uid).get();
    const customerId: string = userSnap.data()?.stripeCustomerId ?? "";

    if (!customerId) {
      return void sendError(res, 404, "no_customer", "No Stripe customer found. Subscribe first.");
    }

    const stripe = getStripe();
    const session = await stripe.billingPortal.sessions.create({
      customer: customerId,
      return_url: "fitcheckai://stripe/portal-return",
    });

    res.status(200).json({ url: session.url });

  } catch (err) {
    if (err instanceof AuthError) return void sendError(res, err.status, err.code, err.message);
    console.error("createBillingPortalSession error:", (err as Error)?.message, err);
    const userMsg = (err as Error)?.message?.includes("not configured")
      ? (err as Error).message
      : "Failed to open billing portal. Please try again.";
    sendError(res, 500, "server_error", userMsg);
  }
});
