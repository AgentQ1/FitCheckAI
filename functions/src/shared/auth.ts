import * as admin from "firebase-admin";
import { Request } from "firebase-functions/v2/https";
import type { Response } from "express";

export interface AuthedUser {
  uid: string;
  email: string;
}

export async function requireAuth(req: Request): Promise<AuthedUser> {
  const authHeader = req.headers.authorization;
  if (!authHeader?.startsWith("Bearer ")) {
    throw new AuthError(401, "unauthorized", "Missing or invalid Authorization header.");
  }
  const token = authHeader.replace("Bearer ", "");
  try {
    const decoded = await admin.auth().verifyIdToken(token);
    return { uid: decoded.uid, email: decoded.email ?? "" };
  } catch {
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
