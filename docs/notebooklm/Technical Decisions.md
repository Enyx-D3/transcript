# Technical Decisions

## Local-First AI

Decision:

Run Whisper, diarization, transcript summaries, transcript Q&A, typo fixing, and general chat on-device.

Why:

- Protects sensitive meeting/audio content.
- Enables offline or low-connectivity workflows after models are downloaded.
- Avoids recurring cloud LLM/STT costs for each transcript.

Tradeoffs:

- Larger app/model storage footprint.
- Device performance variability.
- More complex isolate/background orchestration.

## ObjectBox For Local Database

Decision:

Use ObjectBox rather than SQLite/Drift/Hive for structured local data.

Why:

- Fast local object storage.
- Entity relations/backlinks fit transcripts and turns.
- Supports indexes and generated type-safe queries.

Tradeoffs:

- Requires generated files and schema management.
- Less familiar to some Flutter developers than SQLite.

## Foreground Task Services For Long Work

Decision:

Use `flutter_foreground_task` for recording/transcription runtime state, especially on Android.

Why:

- Long transcription/recording must survive navigation and remain visible to the OS.
- Foreground notifications can show progress.
- Shared task data bridges UI and task contexts.

Tradeoffs:

- Platform-specific behavior.
- iOS requires a separate direct-recording path.
- Runtime state is split across ObjectBox and foreground task storage.

## Separate Recording And Transcription Services

Decision:

Recording and transcription are separate services.

Why:

- Recording produces a WAV.
- Transcription can be started later or from imported files.
- Imported audio/video and recording share the same transcriber.

Tradeoffs:

- More lifecycle coordination.
- Requires busy flags to prevent overlapping jobs.

## Custom Diarization Instead Of Relying On Whisper

Decision:

Use ONNX speaker embeddings/segmentation and custom clustering.

Why:

- Enables speaker turns and known-speaker matching.
- More control over thresholds, target speaker counts, and fallback behavior.

Tradeoffs:

- More model assets.
- More complex audio slicing and clustering.
- Accuracy depends on thresholds and enrollment quality.

## Hierarchical Summarization

Decision:

Split long transcripts into chunks, summarize chunks, then merge summaries.

Why:

- Keeps local LLM context manageable.
- Gives more stable output for long transcripts.
- Allows final response to stream while chunk work stays internal.

Tradeoffs:

- Can lose details between chunk and merge.
- More total model calls.

## Local Premium Unlock With Remote Reconciliation

Decision:

Set local premium active after purchase before or regardless of remote verification success.

Why:

- Avoids punishing users for network/server errors after store purchase.
- Improves purchase UX.

Tradeoffs:

- Remote profile may lag local entitlement.
- Cross-device eligibility still depends on edge verification.

## Soft Delete With Three-Day Purge

Decision:

Move transcripts to trash before permanent deletion.

Why:

- Prevents accidental permanent loss of valuable transcripts.
- Gives a simple recovery window.

Tradeoffs:

- Audio/text remains on disk until purge or explicit permanent delete.

## Glass UI System

Decision:

Build a custom glass design system rather than standard Material surfaces.

Why:

- Gives the product a distinctive premium identity.
- Provides reusable styling primitives across pages, sheets, and buttons.

Tradeoffs:

- More performance care needed with blur/backdrop layers.
- More custom widgets to maintain.

