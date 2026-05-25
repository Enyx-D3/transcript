# UI/UX

## Visual Direction

The app uses a dark glassmorphism visual system. It is not default Material styling; most surfaces are transparent/scaffoldless so the global `GlassBackground` wallpaper can show through.

Core UI primitives:

- `LiquidGlass`
- `GlassBackground`
- `GlassCard`
- `GlassButton`
- `GlassChip`
- `GlassDivider`
- `GlassDock`
- `GlassModal`
- `GlassTokens`

Why this system exists:

The app tries to make a technical workflow feel premium, calm, and spatial. The glass layer also creates a consistent design language across tabs, sheets, dialogs, and cards.

## Global App Theme

Defined in `lib/main.dart`:

- `Brightness.dark`.
- Material 3 enabled.
- Transparent scaffold background.
- White/black focused color scheme.
- Splash/highlight/hover effects suppressed.
- Text colors softened with alpha.
- Global builder wraps all content in `GlassBackground`.

## Main Navigation

`HomeShell` contains five bottom-navigation positions:

- Timeline.
- Calendar.
- Record action.
- Search.
- Favorites.

Record is intentionally not a page. Tapping it opens `RecordSheet`.

## Timeline UX

Timeline acts as the main hub:

- Header with model-downloading status pill.
- Quick actions grid: Enroll Voice, People, YouTube Transcript, Audio File, Video File, Phone Call.
- Sortable transcript list.
- Favorite and delete actions per row.
- Source tags for YouTube/audio/video.
- Long-press Settings icon can reset onboarding flags in debug-like behavior.

## Access Lock UX

Non-eligible users can see an overlay that blocks interactions. iOS has a special local-premium bypass path. The lock exists because entitlement checks may be remote and not all features should be available without verified access.

## Onboarding/Paywall UX

Timeline first-open logic can:

- Prompt for default transcription language once.
- Show paywall once for non-iOS users.
- Show rating prompt through `RateGate`.

Why this sequence exists:

Language choice affects the quality of early transcriptions, while the paywall/eligibility path monetizes usage. The code intentionally shows language before paywall.

## Recording UX

The record sheet:

- Prevents starting another transcription while `busy_transcribing` is active and the foreground service is running.
- Hydrates recording state from task storage.
- Lets the user set target speaker count and language preferences.
- Navigates to transcript detail after stop/start transcription.

## Import UX

Audio/video import sheets:

- Use a 70% height modal sheet.
- Show file picker panels.
- Support language and diarization controls.
- Convert/extract before navigating to detail.
- Block duplicate transcription via the same busy flag.

## Transcript Detail UX

Detail is the core transcript workspace:

- Shows title, metadata, progress state, turns, and audio controls where available.
- Allows title/speaker/turn/whole transcript editing.
- Opens Summary and Ask AI surfaces.
- Supports export/copy/report.
- Tracks foreground transcription progress from shared keys.

## AI UX

Model availability is explicit:

- Timeline auto-starts the GGUF model download if missing.
- Model picker exposes model status and download/cancel.
- Chat/summary pages show model-required banners when missing.
- AI output streams live into bubbles or summary text.

Why streaming exists:

Local LLM generation can be slow. Streaming gives immediate feedback and lets the user trust that work is happening.

## Trash UX

Deleting moves transcripts to trash, not immediate permanent removal. Trash:

- Allows restore.
- Allows immediate permanent delete.
- Automatically purges items older than three days.

Why it exists:

Transcripts can be high-value meeting records, so soft delete reduces accidental data loss.

## HIPAA-Friendly UX

The `HipaaFriendlyPage` explains local storage and sensitive-data handling. It is not a formal compliance module, but it signals intended privacy posture and gives user guidance.

