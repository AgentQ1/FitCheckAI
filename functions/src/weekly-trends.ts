import { onRequest } from "firebase-functions/v2/https";
import * as admin from "firebase-admin";
import { sendError } from "./shared/auth";
import { getOpenAI } from "./shared/openai";

const db = admin.firestore();

// Client reads weekly_trends directly from Firestore — this function is for generating new trends
export const generateWeeklyTrend = onRequest(
  { timeoutSeconds: 120, cors: true },
  async (req, res) => {
    if (req.method === "OPTIONS") { res.status(204).send(""); return; }

    try {
      // Only POST
      if (req.method !== "POST") { res.status(405).json({ error: "method_not_allowed" }); return; }

      // Check if a trend already exists for this week
      const weekStart = getWeekStart();
      const existingSnap = await db.collection("weekly_trends")
        .where("weekStartDate", "==", weekStart)
        .limit(1)
        .get();

      if (!existingSnap.empty) {
        res.status(200).json({ trend: existingSnap.docs[0].data(), cached: true });
        return;
      }

      // Generate a new trend using GPT-4o
      const openai = getOpenAI();
      const completion = await openai.chat.completions.create({
        model: "gpt-4o",
        max_tokens: 1500,
        response_format: { type: "json_object" },
        messages: [
          {
            role: "system",
            content: `You are a fashion trend analyst focused on Gen Z and contemporary street style.
Generate a weekly fashion trend report in JSON format.
Return ONLY valid JSON with this exact structure:
{
  "title": "short catchy trend title",
  "shortDescription": "2-3 sentence description of the trend",
  "styleTags": ["tag1", "tag2", "tag3", "tag4", "tag5"],
  "colors": ["Color Name 1", "Color Name 2", "Color Name 3", "Color Name 4"],
  "outfitExamples": ["example outfit 1", "example outfit 2", "example outfit 3"],
  "dos": ["do tip 1", "do tip 2", "do tip 3", "do tip 4"],
  "donts": ["dont tip 1", "dont tip 2", "dont tip 3"]
}`,
          },
          {
            role: "user",
            content: `Generate a fresh, current fashion trend for the week of ${weekStart.toDateString()}.
Focus on what's actually trending in Gen Z, streetwear, and contemporary fashion right now.
Make it specific, actionable, and culturally relevant.
The trend should be something a college student or young professional would find inspiring.`,
          },
        ],
      });

      const raw = completion.choices[0]?.message?.content ?? "{}";
      let trendData: Record<string, unknown>;
      try {
        trendData = JSON.parse(raw);
      } catch {
        res.status(500).json({ error: "parse_error", message: "Failed to parse AI trend response" });
        return;
      }

      const docData = {
        ...trendData,
        weekStartDate: admin.firestore.Timestamp.fromDate(weekStart),
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      };

      const docRef = await db.collection("weekly_trends").add(docData);
      const savedDoc = await docRef.get();

      res.status(201).json({ trend: savedDoc.data(), id: docRef.id });
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : "Unknown error";
      sendError(res, 500, "internal_error", msg);
    }
  }
);

// Helper: get the Monday of the current week at midnight UTC
function getWeekStart(): Date {
  const now = new Date();
  const day = now.getUTCDay();
  const diff = (day === 0 ? -6 : 1) - day;
  const monday = new Date(now);
  monday.setUTCDate(now.getUTCDate() + diff);
  monday.setUTCHours(0, 0, 0, 0);
  return monday;
}
