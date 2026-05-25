# Project Overview

## Product Identity

`transcript` is a Flutter application for recording, importing, transcribing, organizing, summarizing, and asking questions about meeting/audio/video transcripts. The app is built around a local-first privacy posture: audio, transcripts, speaker profiles, summaries, and chat history are stored on the device in ObjectBox or local files, while cloud systems are used mostly for account eligibility, purchase verification, account deletion, reporting, email delivery, and model downloads.

The user-facing product name appears as `Transcript`, with support and web services hosted under `enyx.app`. The public README is still the default Flutter scaffold, so most product knowledge lives in the source code.

## Core Purpose

The app exists to make long-form spoken content searchable and actionable:

- Record microphone audio and convert it into speaker-attributed transcripts.
- Import audio/video files and transcribe them using the same pipeline.
- Fetch and save YouTube transcripts.
- Enroll known voices so diarization can label speakers by name instead of generic `S1`, `S2`.
- Run local LLM features such as transcript summaries, transcript Q&A, general AI chat, prompt rewriting, and typo correction.
- Export, share, email, favorite, search, delete, restore, and permanently purge transcript records.

## Current State

The repository is an active Flutter app, not a minimal prototype. It contains:

- Auth/eligibility gates backed by Supabase.
- In-app purchase support for Android and iOS.
- Supabase Edge Functions for Apple/Google purchase verification and account deletion.
- ObjectBox entities for transcripts, turns, jobs, summaries, chats, speaker memory, and YouTube metadata.
- Local AI assets for Whisper and ONNX diarization.
- Download services for larger Whisper models and an IBM Granite GGUF model used through `fllama`.
- Foreground/background task services for recording and transcription.
- A glass-style dark UI system with reusable `LiquidGlass`, `GlassCard`, `GlassButton`, `GlassChip`, `GlassDock`, and related primitives.

## Major Technologies

- Flutter/Dart for the application.
- ObjectBox for local structured persistence.
- SharedPreferences for small user preferences and transient flags.
- `flutter_foreground_task` for Android foreground services and shared task state.
- Direct `record` package recording on iOS, foreground service recording on Android.
- `whisper_flutter_new` for on-device Whisper transcription.
- `sherpa_onnx` and ONNX speaker embedding models for diarization.
- `fllama` with a local GGUF model for LLM features.
- Supabase Auth, Postgres tables, and Edge Functions for account/subscription control.
- `in_app_purchase`, StoreKit, and Google Play Billing for monetization.
- Netlify-style functions at `https://enyx.app/.netlify/functions/*` for transcript email and report submission.

## Dependency And Framework Inventory

Core Flutter/runtime dependencies:

- `flutter`, `cupertino_icons`
- `path_provider`, `path`, `shared_preferences`
- `permission_handler`, `url_launcher`, `share_plus`
- `file_picker`, `http`, `dio`, `archive`, `pdf`
- `another_flushbar`, `in_app_review`, `uuid`

Audio and AI dependencies:

- `record` for microphone capture.
- `whisper_flutter_new` for on-device Whisper.
- `sherpa_onnx` for ONNX speaker embedding/diarization support.
- `fllama` from GitHub for local GGUF LLM inference.
- `audioplayers` for enrollment guide/user clip playback.
- `youtube_transcript_api` for YouTube transcript extraction.

Storage/background dependencies:

- `objectbox`, `objectbox_flutter_libs`, `objectbox_generator`, `build_runner`.
- `flutter_foreground_task` for long-running service state.
- `background_downloader` for model downloads that can restore progress.

Auth/billing dependencies:

- `supabase_flutter`
- `google_sign_in`
- `sign_in_with_apple`
- `in_app_purchase`
- `in_app_purchase_android`
- `in_app_purchase_storekit`

Platform/deployment dependencies:

- Android Gradle/Kotlin project under `android/`.
- iOS/macOS CocoaPods projects under `ios/` and `macos/`.
- Linux and Windows Flutter runners are present.
- Supabase Edge Functions use Deno, Supabase JS, and `jose` for Google service-account JWT signing.

## Repository Map

```text
lib/
  main.dart                         App bootstrap, Supabase init, ObjectBox init, background-result listener
  home_shell.dart                   Main tab shell and access lock overlay
  objectbox/                        Local DB bootstrap and entities
  transcript/                       Transcription, detail, import, YouTube, summary, chat modules
  record/                           Current recording sheet/service
  auth/                             Guest ID, app gate, eligibility, login/profile scaffolding
  billing/                          In-app purchase and product IDs
  tabs/                             Timeline, search, favorites, AI chat, account
  onboarding/                       Speaker voice enrollment flow
  debug/                            Speaker memory management UI
  export/                           TXT/PDF export services and sheet
  import_export/                    ZIP backup/restore of transcripts
  settings/                         Preferences, account/settings links
  ui/glass/                         Custom glass design system
backend/supabase/
  config.toml                       Local Supabase config and function declarations
  functions/                        Edge functions for purchase verification and account deletion
assets/
  models/                           Bundled Whisper tiny, segmentation ONNX, speaker embedding ONNX
  instruction/                      Voice enrollment guide audio
  logo/, wallpapers/, fonts/        Brand/design assets
```

## Key Product Principle

The app is designed so high-sensitivity work happens locally. Audio conversion, preprocessing, diarization, transcription, AI summarization, transcript Q&A, and typo fixing are all local-device paths when models are available. Cloud services validate commercial/account access and help with user support/reporting, but the core transcript intelligence is device-side.
