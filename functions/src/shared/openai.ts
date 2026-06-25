import OpenAI from "openai";

let _client: OpenAI | null = null;

export function getOpenAI(): OpenAI {
  if (!_client) {
    _client = new OpenAI({ apiKey: process.env.OPENAI_API_KEY! });
  }
  return _client;
}

export type ModerationVerdict = {
  /** True only when the model positively flagged objectionable content. */
  flagged: boolean;
  categories: string[];
  /** True when we could NOT get a definitive verdict (API error / empty result). */
  errored: boolean;
};

/**
 * Objectionable-content filter for user-generated images (Apple Guideline 1.2).
 *
 * Runs OpenAI's multimodal moderation model on the outfit photo before it can enter
 * any PUBLIC surface (the Arena). Returns three distinct outcomes so the CALLER can be
 * FAIL-CLOSED for public content:
 *   - flagged:true              → objectionable → caller marks the fit `rejected`
 *   - flagged:false errored:false → clean verdict → caller may mark `approved`
 *   - errored:true              → undetermined (API hiccup / empty result) → caller
 *                                  must NOT approve; it marks the fit `pending`
 *
 * This function never throws and never blocks a user's own PRIVATE analysis — it only
 * reports the verdict. Public visibility is decided by the caller, which treats
 * anything other than a positive clean verdict as "not public yet".
 */
export async function moderateImageURL(url: string): Promise<ModerationVerdict> {
  try {
    const res = await getOpenAI().moderations.create({
      model: "omni-moderation-latest",
      input: [{ type: "image_url", image_url: { url } }],
    });
    const result = res.results?.[0];
    // No result row → we cannot vouch for the image. Fail-closed: report as errored.
    if (!result) return { flagged: false, categories: [], errored: true };
    const categories = Object.entries(result.categories ?? {})
      .filter(([, on]) => on === true)
      .map(([name]) => name);
    return { flagged: result.flagged === true, categories, errored: false };
  } catch (e) {
    console.warn("[moderateImageURL] moderation failed (fail-closed → pending):", (e as Error)?.message);
    return { flagged: false, categories: [], errored: true };
  }
}

export const SYSTEM_PROMPT = `You are StyleAI, an expert AI fashion analyst with deep knowledge across all major style aesthetics: Gen Z, streetwear, old money/luxury, business professional, smart casual, athleisure, cottagecore, Y2K, and more.

Your role is to analyze outfit photos and provide structured, honest, fashion-focused feedback. You focus EXCLUSIVELY on clothing, accessories, shoes, color coordination, fit, proportion, and overall style presentation.

CRITICAL RULES:
1. NEVER comment on the person's face, body shape, weight, skin tone, or physical attractiveness.
2. NEVER use body-shaming language, even subtly.
3. NEVER comment on race, ethnicity, or cultural background.
4. ALWAYS frame feedback constructively — "this could be elevated by..." not "this is bad because..."
5. ALWAYS maintain a supportive, fashion-mentor tone.
6. Rate the OUTFIT, not the person.
7. If photo quality is poor or outfit is unclear, lower your confidence score and note it.
8. If the image does not appear to contain an outfit/person, return an error JSON instead.

SCORING PHILOSOPHY:
- Scores are relative to the stated style goal and occasion.
- A score of 7/10 means "well-executed, minor improvements available."
- A score of 9+/10 means "professionally styled, minimal changes needed."
- Never give a 10/10 — there is always something to refine.
- Calibrate scores against real-world fashion standards, not just effort.

OUTPUT: Return ONLY valid JSON. No explanation text before or after. No markdown code fences.`;

export function buildUserPrompt(styleGoal: string): string {
  return `Analyze the outfit in this image. The user's stated style goal is: ${styleGoal}.

Return a JSON object with exactly this structure:

{
  "overall_score": <float 0-9.9>,
  "gen_z_score": <float 0-9.9>,
  "professional_score": <float 0-9.9>,
  "date_night_score": <float 0-9.9>,
  "luxury_score": <float 0-9.9>,
  "streetwear_score": <float 0-9.9>,
  "campus_score": <float 0-9.9>,
  "gym_score": <float 0-9.9>,
  "interview_score": <float 0-9.9>,
  "color_score": <float 0-9.9>,
  "fit_score": <float 0-9.9>,
  "occasion_score": <float 0-9.9>,
  "shoes_accessories_score": <float 0-9.9>,
  "photo_quality_score": <float 0-9.9>,
  "trend_score": <float 0-9.9>,
  "verdict": "<one of: Iconic | Chef's Kiss | Fire Fit | Clean AF | Solid Look | Good Energy | Almost There | Needs Work | Room to Grow>",
  "style_personality": "<2-4 word style archetype>",
  "confidence_level": "<High | Medium | Low>",
  "what_works": ["<string>", "<string>", "<string>"],
  "what_to_improve": ["<string>", "<string>", "<string>"],
  "best_one_change": "<string: single most impactful change with expected score delta>",
  "color_analysis": {
    "palette_description": "<string>",
    "harmony_type": "<string>",
    "dominant_colors": ["<color1>", "<color2>", "<color3>"],
    "color_issues": "<string or null>"
  },
  "detected_items": {
    "top": "<string or null>",
    "bottom": "<string or null>",
    "outerwear": "<string or null>",
    "shoes": "<string or null>",
    "accessories": ["<string>"],
    "overall_silhouette": "<string>"
  },
  "improved_looks": [
    {
      "title": "Small Upgrade",
      "theme": "<string>",
      "expected_score": <float>,
      "changes": [{"item": "<string>", "change": "<string>", "reason": "<string>"}],
      "image_generation_prompt": "<detailed DALL-E prompt>"
    },
    {
      "title": "Gen Z Upgrade",
      "theme": "<string>",
      "expected_score": <float>,
      "changes": [...],
      "image_generation_prompt": "<string>"
    },
    {
      "title": "Luxury Upgrade",
      "theme": "<string>",
      "expected_score": <float>,
      "changes": [...],
      "image_generation_prompt": "<string>"
    }
  ],
  "error": null
}

If no outfit is visible: return {"error": "no_outfit_detected", "error_message": "No outfit detected. Please upload a full-body or upper-body photo.", "overall_score": null}
If photo is too blurry/dark: return {"error": "poor_photo_quality", "error_message": "Photo is too dark or blurry for accurate analysis.", "overall_score": null, "photo_quality_score": 1.5}`;
}
