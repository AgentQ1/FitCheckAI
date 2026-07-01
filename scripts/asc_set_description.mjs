#!/usr/bin/env node
/**
 * Add the Terms of Use (EULA) + Privacy Policy links to the App Store
 * description to resolve guideline 3.1.2 (auto-renewable subscriptions must
 * link to the Terms of Use in metadata). Uses the standard Apple EULA.
 *
 * Usage: node scripts/asc_set_description.mjs <localizationId> [--dry]
 */
import { asc } from "./asc.mjs";

const [, , locId, flag] = process.argv;
if (!locId) {
  console.error("Usage: asc_set_description.mjs <appStoreVersionLocalizationId> [--dry]");
  process.exit(2);
}

const description = `Snap a photo of your outfit and get an instant, honest AI fit score in seconds. FitCheck rates your look, breaks down what works (and what doesn't), and shows you AI-upgraded versions of your outfit so you always step out with confidence.

WHAT YOU GET
- Instant AI fit score: a clear rating with specific, useful feedback on fit, color, and style.
- AI outfit upgrades: see reimagined versions of your look with smarter styling suggestions.
- Style insights: understand your strengths and how to level up your wardrobe.
- The Arena: share your best fits, vote on others, and climb the daily and weekly leaderboards.
- Track your progress: watch your style score improve over time.

PREMIUM
FitCheck Premium unlocks unlimited fit checks, premium style insights, and AI outfit upgrades.
- Monthly and yearly subscription options.
- Payment is charged to your Apple ID account at confirmation of purchase.
- Subscriptions renew automatically unless canceled at least 24 hours before the end of the current period.
- Manage or cancel anytime in your App Store account settings.

Terms of Use (EULA): https://www.apple.com/legal/internet-services/itunes/dev/stdeula/
Privacy Policy: https://fitcheck-d3091.web.app/privacy

Whether you're heading to work, a night out, or a special event, FitCheck is your pocket stylist for an honest second opinion.`;

if (flag === "--dry") {
  console.log(`length=${description.length}\n----\n${description}`);
  process.exit(0);
}

const body = {
  data: {
    type: "appStoreVersionLocalizations",
    id: locId,
    attributes: { description },
  },
};

const r = await asc("PATCH", `/v1/appStoreVersionLocalizations/${locId}`, body);
console.log(JSON.stringify({ status: r.status, ok: r.ok, body: r.body }, null, 2));
process.exit(r.ok ? 0 : 1);
