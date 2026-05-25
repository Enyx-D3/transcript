# Current Features

## Recording

The recording feature lets users capture microphone audio into WAV files and then pass those files to the transcription pipeline.

Implemented behavior:

- Record from the center action in the bottom dock.
- Pause/resume/stop recording.
- Save recording runtime state through `flutter_foreground_task` keys such as `rec_file_path`, `rec_start_epoch_ms`, `rec_paused`, and `rec_last_elapsed_sec`.
- Enforce a configurable maximum recording duration from `pref_max_recording_minutes`.
- Use Android foreground services for long-running recording.
- Use direct `record` package capture on iOS while mimicking foreground-task events for UI consistency.
- Store recordings under the app documents/support directory with names like `rec_<timestamp>.wav`.

Why it exists:

Recording is the primary source of native transcripts. The implementation separates capture from transcription so the UI can create a placeholder transcript, navigate immediately to the detail page, and let the background transcriber finish later.

## Audio File Import

Implemented behavior:

- Accepts `wav`, `mp3`, `m4a`, `aac`, `ogg`, `flac`, and `mp4`.
- Uses `file_picker` with stream fallback when a direct path is unavailable.
- Converts source audio to 16 kHz mono WAV through `AudioConverterService`.
- Creates a `TranscriptEntity` with `sourceType = 2`.
- Creates a `TranscriptionJobEntity` and starts `BackgroundTranscriber`.
- Supports language selection and optional target speaker count.

Why it exists:

Imported audio uses the same downstream transcription pipeline as recordings, which avoids duplicate AI logic and keeps saved transcripts consistent.

## Video File Import

Implemented behavior:

- Accepts `mp4`, `mkv`, `mov`, `webm`, `m4v`, `3gp`, and `avi`.
- Extracts audio into 16 kHz mono WAV through the same converter abstraction.
- Creates a `TranscriptEntity` with `sourceType = 3`.
- Starts background transcription against the extracted WAV.

Why it exists:

Video import expands the app from meeting recording to broader media transcription while preserving the same local transcription and diarization architecture.

## YouTube Transcripts

Implemented behavior:

- Users paste a YouTube URL.
- The app extracts a video ID and calls `youtube_transcript_api`.
- Manual and auto-generated transcript tracks are fetched with a delay between requests to reduce rate-limit failures.
- Fetched tracks are saved into ObjectBox as `YoutubeTranscriptMetaEntity` and `YoutubeTranscriptTextEntity`.
- A corresponding `TranscriptEntity` is upserted with `sourceType = 1`, `model = youtube`, `lang = multi`, and `youtubeMetaId`.
- Saved YouTube transcript pages can export/share transcript text.

Why it exists:

YouTube transcript capture is a low-cost way to bring external spoken content into the same timeline, search, favorites, and export surfaces without running Whisper.

## Speaker Enrollment And Identification

Implemented behavior:

- Guided voice setup flow with multiple prompt clips.
- Records short samples and preprocesses them into normalized WAV.
- Extracts speaker embeddings from windows of each clip.
- Stores multiple embedding prototypes per speaker name in `speaker_memory.json`.
- Diarization can load these prototypes and map anonymous clusters to enrolled names when cosine similarity passes threshold.
- Debug/People screen can inspect, copy, delete, and clear speaker memory.

Why it exists:

Raw diarization produces generic speaker labels. Enrollment lets recurring speakers become recognizable people, making transcripts easier to read and search.

## Transcription With Diarization

Implemented behavior:

- Preprocesses audio to 16 kHz mono.
- Reads preferences for translation and diarization.
- If diarization is disabled, runs a single Whisper pass and saves one `S1` turn.
- If diarization is enabled, runs embedding diarization in an isolate.
- Falls back to in-thread diarization if isolated diarization fails.
- Slices audio by speaker segments and runs Whisper per segment.
- Merges adjacent same-speaker segments.
- Emits progress stages: `Preparing`, `Diarizing`, `Transcribing`, `Finalizing`.
- Optionally runs local typo correction before persisting the result if the GGUF model is available.

Why it exists:

Running Whisper per diarized segment makes turn-level speaker attribution possible even though Whisper itself is only used for text.

## Transcript Detail And Editing

Implemented behavior:

- Displays saved transcript turns ordered by start time.
- Supports title editing.
- Supports speaker rename.
- Supports single-turn editing.
- Supports whole-transcript editing through `TranscriptEditorPage`.
- Supports copy and export.
- Supports original/enhanced/processed audio path handling where available.
- Tracks background progress while transcription is running.
- Can open summary and transcript chat pages.
- Can report AI/transcript output.
- Can auto-generate summary once per transcript if enabled.

Why it exists:

The detail page is the workspace for turning raw transcript output into usable notes, exports, and AI interactions.

## Summaries

Implemented behavior:

- Uses local LLM via `LLMService.summarizeTranscript`.
- Offers summary length preferences: short, balanced, detailed.
- Splits long transcript text into chunks, summarizes chunks silently, then streams a final merged summary.
- Persists one summary per transcript in `TranscriptSummaryEntity`.
- Uses shared busy flags such as `summary_busy_<id>` to coordinate auto/manual generation.
- Supports copy, export, and report actions.

Why it exists:

Meeting transcripts are often too long to consume directly. Summaries extract decisions, action items, risks, and open questions.

## Transcript Q&A

Implemented behavior:

- Each transcript has a chat page.
- User asks questions against that transcript.
- Turns are converted into speaker-prefixed text and passed to `LLMService.qaOnTranscript`.
- The prompt instructs the model to answer strictly from transcript context and say it does not know if absent.
- Messages persist in ObjectBox as `TranscriptChatMessageEntity`.
- Assistant output streams into the UI and is throttled into DB writes.

Why it exists:

Q&A turns transcripts into a searchable knowledge artifact without sending private meeting text to a remote LLM.

## General AI Chat

Implemented behavior:

- `AiChatTab` stores a single general chat history in ObjectBox as `AiChatMessageEntity`.
- Uses the same local GGUF model and Qwen-style chat template.
- Streams assistant output and persists it incrementally.
- Supports copy/report/clear.

Why it exists:

The app includes a broader on-device assistant surface separate from transcript-specific Q&A.

## Search, Favorites, Timeline, Calendar, Trash

Implemented behavior:

- Timeline lists non-deleted transcripts and supports sort by date/title.
- Favorites are a boolean flag on `TranscriptEntity`.
- Search tab queries saved transcripts.
- Calendar page groups transcripts by date.
- Trash uses soft delete (`isDeleted`, `deletedAt`) and permanently purges after three days.
- Permanent delete cascades turns, summaries, chats, YouTube metadata/texts, and audio files where applicable.

Why it exists:

These surfaces make the app function as a personal transcript archive, not only a one-off recorder.

## Import/Export And Sharing

Implemented behavior:

- Export transcript or summary as document formats through `DocumentExportService`.
- Share YouTube transcript text files.
- ZIP backup/restore supports current transcript payloads including YouTube metadata and audio.
- Auto-email can send TXT attachments after transcription completes when enabled.

Why it exists:

Users need to move transcripts into external workflows such as email, notes, document storage, or backup.

## Billing And Access

Implemented behavior:

- Product IDs for monthly, yearly, and lifetime products.
- Android and iOS purchase flows with restore/reconcile.
- Local premium flag for immediate local unlock.
- Supabase Edge Functions verify purchase tokens and update remote profile eligibility.
- Android non-iOS users are gated by remote eligibility; iOS premium local state can unlock if remote check fails.

Why it exists:

Subscription and lifetime purchases monetize unlimited transcription while preserving a responsive local experience.

