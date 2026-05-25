# Known Issues

## Documentation Gap

The root `README.md` is still the default Flutter template and does not describe the actual app, architecture, setup, or deployment.

Impact:

New contributors must reverse-engineer behavior from source code.

## Hardcoded Supabase URL And Anon Key

`lib/main.dart` embeds the Supabase project URL and anon key directly.

Impact:

This is normal for public anon keys in many Supabase clients, but environment separation is harder and accidental production coupling is likely.

## Summary Report Placeholder

`TranscriptSummaryPage` constructs:

```dart
ReportService(baseUrl: 'YOUR_BASE_URL_HERE')
```

Impact:

Reporting a summary may post to an invalid URL, while other report surfaces use `https://enyx.app`.

## Android Package Default Mismatch

The Android edge function default package is:

```text
com.fllama.transcript
```

The app package path suggests:

```text
com.enyxd.transcript
```

Impact:

If `ANDROID_PACKAGE_NAME` is not set in production edge function secrets, Google Play verification can fail.

## Qwen Naming Versus Granite Model

The code uses:

- `QwenModelService`
- Qwen chat template tokens
- `qwenMaxContext`

But downloads:

- `granite-4.0-350m-Q4_K_M.gguf`

Impact:

If Granite does not expect the Qwen chat template, output quality may degrade. If it does tolerate the template, names are still misleading for maintainers.

## Full Prompt Logging

`LLMService._runChat` logs:

```dart
debugPrint('Qwen prompt: $qwenPrompt');
```

Impact:

Prompts can contain full transcript text, sensitive meeting content, or user chat history. Even debug logs can be risky for a privacy-focused app.

## Duplicate Module Paths

There are both:

- `lib/record/recording_service.dart`
- `lib/transcript/recording_service.dart`
- `lib/record/record_sheet.dart`
- `lib/transcript/record_sheet.dart`

Current imports often use `lib/record/*`, while older paths still exist.

Impact:

Bug fixes may be applied to one copy but not the other. This increases maintenance risk.

## Speaker Storage Split

ObjectBox defines `SpeakerProfileEntity` and `SpeakerVectorEntity`, but active enrollment/matching uses `speaker_memory.json`.

Impact:

Future People features can diverge from the actual diarization memory unless storage is unified.

## ObjectBox Generated File In Repo

`lib/objectbox.g.dart` is checked in, which is normal for ObjectBox Flutter projects in some workflows, but it requires regeneration when entities change.

Impact:

Entity changes must be accompanied by generated model updates.

## Generated Build Artifacts In Repo

The file list includes `ios/build/...` and `android/build/reports/...`.

Impact:

Generated artifacts add noise and can confuse repository analysis, diffs, and onboarding.

## Login Page Commented Out

`lib/auth/login_page.dart` contains a large commented auth implementation.

Impact:

It is unclear whether auth UI is intentionally disabled, replaced by account tab flows, or temporarily paused.

## YouTube Rate Limit Handling Is Defensive But Limited

The YouTube fetch flow delays between tracks and converts rate-limit errors to a friendly message.

Impact:

Users can still save tracks containing the rate-limit message as text if rate-limited mid-fetch.

## Search Cache Maintenance May Be Incomplete

Entities include `fullTextCache` and `searchText`, but persistence shown in `transcription_persistence.dart` writes turns and parent metadata without clearly updating these fields.

Impact:

Search quality may depend on other pages updating caches, or search may miss freshly persisted transcripts.

## Auto-Download Without Consent

Timeline auto-starts the GGUF model download when missing. There is a `ModelDownloadConsent` helper, but the Timeline flow currently says auto-download with no confirmation.

Impact:

Large model downloads can surprise users on cellular or limited storage.

