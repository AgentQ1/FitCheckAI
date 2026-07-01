import * as admin from "firebase-admin";
import { Request } from "firebase-functions/v2/https";
import type { Response } from "express";

export interface AuthedUser {
  uid: string;
  email: string;
  /** Firebase sign-in provider, e.g. "apple.com", "google.com", or "anonymous". */
  provider: string;
  /** True for an anonymous (guest) session. Guests get a single free fit check. */
  isAnonymous: boolean;
}

export async function requireAuth(req: Request): Promise<AuthedUser> {
  const authHeader = req.headers.authorization;

  if (!authHeader?.startsWith("Bearer ")) {
    throw new AuthError(401, "unauthorized", "Missing or invalid Authorization header.");
  }
  const token = authHeader.slice("Bearer ".length).trim();

  if (!token) {
    throw new AuthError(401, "unauthorized", "Empty bearer token.");
  }
  // Firebase ID tokens are JWTs with exactly two dots — short-circuit obviously
  // malformed tokens before paying for a verifyIdToken round-trip.
  if ((token.match(/\./g) ?? []).length !== 2) {
    throw new AuthError(401, "unauthorized", "Token is not in JWT format.");
  }

  try {
    const decoded = await admin.auth().verifyIdToken(token);
    const provider = (decoded.firebase?.sign_in_provider as string | undefined) ?? "unknown";
    return {
      uid: decoded.uid,
      email: decoded.email ?? "",
      provider,
      isAnonymous: provider === "anonymous",
    };
  } catch (err) {
    console.error("[requireAuth] verifyIdToken failed:", (err as Error)?.message);
    throw new AuthError(401, "unauthorized", "Invalid or expired token.");
  }
}

export class AuthError extends Error {
  constructor(
    public readonly status: number,
    public readonly code: string,
    message: string
  ) {
    super(message);
  }
}

export function sendError(res: Response, status: number, code: string, message: string): void {
  res.status(status).json({ error: code, message });
}

export function corsHeaders() {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "authorization, content-type",
    "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
  };
}
