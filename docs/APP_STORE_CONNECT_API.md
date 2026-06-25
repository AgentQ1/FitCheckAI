# App Store Connect API — FitCheck

A dependency-free helper (`scripts/asc.mjs`) for reading and updating App Store
Connect metadata from the command line. It generates a short-lived ES256 JWT from
your `.p8` key using Node's built-in `crypto` (no npm install required).

## Security

- The private key lives in `private_keys/` and is **git-ignored** (`private_keys/`,
  `*.p8`, `AuthKey_*.p8`). Never commit it.
- Credentials go in `.env.asc.local` (matches the `.env.*` ignore rule). Never commit it.
- The script never prints the private key; JWTs expire after 10 minutes.

## One-time setup

```bash
cp .env.example .env.asc.local   # then fill in ASC_KEY_ID / ASC_ISSUER_ID
# place the key at private_keys/AuthKey_<KEY_ID>.p8
chmod 600 private_keys/*.p8
```

## Usage

```bash
source .env.asc.local

# Read-only examples
node scripts/asc.mjs GET "/v1/apps?filter[bundleId]=ai.fitcheck.app"
node scripts/asc.mjs GET "/v1/apps/6782241321/appStoreVersions"

# Update examples (PATCH/POST take a JSON body string)
node scripts/asc.mjs PATCH "/v1/appStoreVersionLocalizations/<id>" \
  '{"data":{"type":"appStoreVersionLocalizations","id":"<id>","attributes":{"keywords":"a,b,c"}}}'
```

Output is `{ status, ok, body }` as JSON; pipe through `jq` to filter.

## FitCheck reference IDs (as of 2026-06-20)

| Resource | ID |
| --- | --- |
| App | `6782241321` (bundle `ai.fitcheck.app`) |
| App Info | `b5b1a53d-6482-4bac-b04b-4d3cf928490d` |
| App Info Localization (en-US) | `ffb4098a-96e0-4dff-9048-949f84293239` |
| App Store Version 1.0 | `e1e50f24-5d56-4e02-a468-e0bf2010adc6` |
| Version Localization (en-US) | `f5d8877e-d26a-4826-892f-49d433234ede` |
| Subscription Group "FitCheck Premium" | `22170133` |
| Monthly subscription | `6782241921` (`com.fitcheckai.premium.monthly`) |
| Yearly subscription | `6782250049` (`com.fitcheckai.premium.yearly`) |
| Build 1.0.0 (2) | `eb1ac56c-f19e-44c6-973a-95f8f959b71b` |

## Common recipes

```bash
# Update marketing/support/privacy URLs on the version + app info
node scripts/asc.mjs PATCH "/v1/appStoreVersionLocalizations/f5d8877e-d26a-4826-892f-49d433234ede" \
  '{"data":{"type":"appStoreVersionLocalizations","id":"f5d8877e-d26a-4826-892f-49d433234ede","attributes":{"supportUrl":"https://...","marketingUrl":"https://..."}}}'

node scripts/asc.mjs PATCH "/v1/appInfoLocalizations/ffb4098a-96e0-4dff-9048-949f84293239" \
  '{"data":{"type":"appInfoLocalizations","id":"ffb4098a-96e0-4dff-9048-949f84293239","attributes":{"privacyPolicyUrl":"https://..."}}}'

# Attach a build to the version
node scripts/asc.mjs PATCH "/v1/appStoreVersions/e1e50f24-5d56-4e02-a468-e0bf2010adc6/relationships/build" \
  '{"data":{"type":"builds","id":"<buildId>"}}'
```

## Things the API does NOT cover (must be done in the ASC web UI)

- **App Privacy** ("nutrition" labels) — no public API endpoint.
- **Screenshots upload** — multi-step reservation/commit; do via the web UI or Fastlane.
- **Final "Submit for Review"** — left to a human by policy.
