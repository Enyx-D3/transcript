# Roadmap

This roadmap is inferred from TODOs, comments, placeholder UI, unused fields, and partially implemented code. Items here should be treated as inferred intent, not confirmed product commitments.

## Explicit Coming Soon

### Phone Call Transcription

Evidence:

- Timeline quick action `Phone Call` calls `_comingSoon()`.

Likely goal:

Support phone-call transcription as another source type, possibly extending `sourceType` beyond the current 0-3 values.

## Partially Implemented Or Planned

### More Source Types

Evidence:

- `TranscriptEntity.sourceType` comment: `0 = voice, 1 = youtube (future: add more sources)`.
- Audio and video imports already use `2` and `3`.

Likely direction:

Additional transcript sources such as phone calls, cloud imports, meetings, or external integrations.

### Video Metadata For YouTube

Evidence:

- `YoutubeTranscriptMetaEntity.title` and `channel` comments say optional fields can be used later if video info is fetched.

Likely direction:

Fetch YouTube title/channel for better timeline labels and search metadata.

### Richer Transcription Job Tracking

Evidence:

- `TranscriptionJobEntity` includes `totalChunks`, `processedChunks`, `currentChunkIndex`, `stage`, `isRecording`, and status values.

Current:

- Jobs are created and marked pending/running/error in import flows, but chunk-level progress is mostly represented through foreground task keys.

Likely direction:

Persistent job queue/progress UI, resumable jobs, or robust recovery after app restarts.

### Account Login Flow

Evidence:

- `lib/auth/login_page.dart` contains a large commented implementation for email/password, Google, Apple sign-in, profile creation, and terms links.
- `AccountTab` has active Supabase profile operations.

Likely direction:

Rebuild or re-enable full authentication UI.

### Speaker Memory Unification

Evidence:

- ObjectBox has speaker profile/vector entities.
- Active code uses `speaker_memory.json`.

Likely direction:

Migrate speaker memory into ObjectBox or keep ObjectBox speaker entities for a richer future People system.

### Optional Segmentation Int8 Model

Evidence:

- `model_bootstrap.dart` references `assets/models/segmentation/model.int8.onnx` as optional.
- `pubspec.yaml` only includes `assets/models/segmentation/model.onnx`.

Likely direction:

Add quantized diarization model support for performance/smaller memory.

### Auto Summary Improvements

Evidence:

- `pref_auto_summary_enabled`.
- `summary_busy_<id>`.
- `auto_summary_ran_once` style behavior in detail page.

Likely direction:

Make summary generation feel automatic and resilient across navigation/background work.

### Report/Feedback Backend Consolidation

Evidence:

- Most report services use `https://enyx.app`.
- Summary page uses placeholder `YOUR_BASE_URL_HERE`.

Likely direction:

Standardize all support/report endpoints and metadata.

## Product Expansion Ideas Implied By Current Architecture

- Cloud sync for transcripts, since Supabase auth exists but transcript data is local-only.
- Cross-device subscription state, already partially supported through profiles.
- More export formats and backup flows, since ZIP and document export exist.
- Better compliance/privacy controls, since HIPAA-friendly messaging and delete-audio-after-transcription are present.
- Advanced speaker management, since enrolled speaker prototypes exist and People/debug screens exist.
- Full-text indexing improvements, since `searchText` and `fullTextCache` exist but maintenance appears uneven.

