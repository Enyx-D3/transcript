# APIs

## Supabase Client Usage

Supabase is initialized in `lib/main.dart` with:

- URL: `https://ncpxlqykawquordwnxmw.supabase.co`
- An anon key embedded in the client.

Client-side Supabase usage:

- Auth session/current user lookup.
- `profiles` table reads/writes.
- Edge function invocation for purchase verification and account deletion.

## Supabase Tables Referenced

### `profiles`

Client and edge functions read/write:

- `id`
- `is_upgraded`
- `is_lifetime`
- `trial_expires_at`
- `pro_expires_at`

Purpose:

Determines whether a signed-in user is eligible for premium/unlimited access.

### `purchase_token_locks`

Edge functions read/write:

- `platform`
- `purchase_token`
- `product_id`
- `user_id`
- `last_seen_at`

Purpose:

Prevents the same Google/Apple purchase token or transaction from being claimed by multiple accounts.

## Supabase Edge Functions

## Environment Variables

Environment variables detected in authored Supabase configuration and edge functions:

Production edge function variables:

- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `SUPABASE_SERVICE_ROLE_KEY`
- `GOOGLE_SERVICE_ACCOUNT_EMAIL`
- `GOOGLE_SERVICE_ACCOUNT_PRIVATE_KEY`
- `ANDROID_PACKAGE_NAME`
- `APPLE_KEY_ID`
- `APPLE_ISSUER_ID`
- `APPLE_PRIVATE_KEY`
- `APPLE_BUNDLE_ID`
- `APPLE_ENVIRONMENT`

Supabase local config variables or commented config hooks:

- `OPENAI_API_KEY`, used by Supabase Studio AI if configured.
- `SECRET_VALUE`, example placeholder for vault/edge runtime secrets.
- `SENDGRID_API_KEY`, example SMTP password placeholder.
- `SUPABASE_AUTH_SMS_TWILIO_AUTH_TOKEN`, Twilio auth token.
- `SUPABASE_AUTH_EXTERNAL_APPLE_SECRET`, Apple OAuth provider secret.
- `S3_HOST`
- `S3_REGION`
- `S3_ACCESS_KEY`
- `S3_SECRET_KEY`

Client constants that behave like environment/config values:

- Supabase URL and anon key are hardcoded in `lib/main.dart`.
- `TranscriptMailService` and `ReportService` mostly use `https://enyx.app` as a base URL.
- Product IDs are hardcoded in `lib/billing/subscription_products.dart`.
- Model download URLs are hardcoded in `WhisperService` and `QwenModelService`.

### `verify-play-subscription`

Path:

- `backend/supabase/functions/verify-play-subscription/index.ts`

Client invocation:

- `Supabase.instance.client.functions.invoke('verify-play-subscription')`

Method:

- POST only.

Request body:

```json
{
  "product_id": "transcript_pro_monthly",
  "purchase_token": "google-play-purchase-token"
}
```

Behavior:

- Validates known product IDs.
- Authenticates user from Supabase JWT.
- Uses Google Android Publisher API to verify lifetime managed products or subscriptions v2.
- Ensures subscriptions are active or in grace period.
- Ensures product ID matches a subscription line item.
- Locks the token to the user in `purchase_token_locks`.
- Updates `profiles.is_upgraded`, `profiles.is_lifetime`, and `profiles.pro_expires_at`.

Required environment variables:

- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `SUPABASE_SERVICE_ROLE_KEY`
- `GOOGLE_SERVICE_ACCOUNT_EMAIL`
- `GOOGLE_SERVICE_ACCOUNT_PRIVATE_KEY`
- `ANDROID_PACKAGE_NAME`, optional, default currently `com.fllama.transcript`

Known concern:

The Android app package in source appears as `com.enyxd.transcript`, while the edge function default is `com.fllama.transcript`. Production likely relies on `ANDROID_PACKAGE_NAME` being set correctly.

### `verify-apple-subscription`

Path:

- `backend/supabase/functions/verify-apple-subscription/index.ts`

Client invocation:

- `Supabase.instance.client.functions.invoke('verify-apple-subscription')`

Method:

- POST only.

Request body:

```json
{
  "product_id": "transcript_pro_monthly_apple",
  "purchase_token": "app-store-receipt-or-jws"
}
```

Behavior:

- Validates product ID against known Apple/legacy IDs.
- Authenticates user from Supabase JWT.
- Verifies with App Store Server API when Apple keys are configured.
- Falls back to legacy `verifyReceipt` when the token is not JWS and server API keys are unavailable.
- Rejects StoreKit 2 JWS verification if server API keys are missing.
- Locks verified transaction ID or token to user.
- Updates `profiles` entitlement fields.

Required environment variables:

- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `SUPABASE_SERVICE_ROLE_KEY`
- `APPLE_KEY_ID`
- `APPLE_ISSUER_ID`
- `APPLE_PRIVATE_KEY`
- `APPLE_BUNDLE_ID`, optional, default `com.enyxdigital.transcript`
- `APPLE_ENVIRONMENT`, optional, default `Production`

### `delete-account`

Path:

- `backend/supabase/functions/delete-account/index.ts`

Client invocation:

- `Supabase.instance.client.functions.invoke('delete-account')`

Behavior:

- Requires Authorization header.
- Gets user from JWT.
- Deletes matching row from `profiles`.
- Deletes auth user through Supabase admin client.

Required environment variables:

- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `SUPABASE_SERVICE_ROLE_KEY`

## External Service APIs

### Model Downloads

Whisper models:

- Host: `https://huggingface.co/ggerganov/whisper.cpp/resolve/main/`
- Files: `ggml-tiny.bin`, `ggml-base.bin`, `ggml-small.bin`, `ggml-medium.bin`

Local LLM model:

- URL: `https://huggingface.co/ibm-granite/granite-4.0-350m-GGUF/resolve/main/granite-4.0-350m-Q4_K_M.gguf?download=true`

### YouTube Transcript API

Package:

- `youtube_transcript_api`

Purpose:

- Lists available transcript tracks.
- Fetches manual and generated transcripts by language code.

### Netlify-Style Functions

Base URL in most code:

- `https://enyx.app`

Endpoints:

- `/.netlify/functions/send-transcript-txt`
- `/.netlify/functions/send-report-transcript`

`TranscriptMailService.sendTxtAttachment` posts transcript emails.

`ReportService.sendReport` posts reports with reason, note, response, and optional metadata.

Known issue:

`TranscriptSummaryPage` initializes `ReportService(baseUrl: 'YOUR_BASE_URL_HERE')`, so summary reporting may fail unless replaced.
