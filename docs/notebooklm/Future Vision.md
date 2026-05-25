# Future Vision

## Product Vision

The project is evolving toward a private, local-first transcript intelligence workspace. The current code already supports the core loop:

1. Capture or import spoken content.
2. Convert it into speaker-attributed text.
3. Store it locally.
4. Summarize, ask questions, search, organize, export, and share.

The natural future vision is not “just a recorder”, but a personal meeting memory system.

## Likely North Star

A user should be able to ask:

- “What did we decide last week?”
- “What action items did Alex take?”
- “Find the meeting where we discussed pricing.”
- “Summarize this client call in a HIPAA-friendly way.”
- “Export all my transcripts before switching phones.”

And the app should answer from local private data with minimal friction.

## Future Directions Enabled By Current Architecture

### Richer Source Coverage

The source-type system can grow to:

- Phone call transcription.
- Cloud meeting imports.
- Voice memos.
- Uploaded files from share sheet.
- Browser/YouTube/Podcast imports.

### Stronger Speaker Intelligence

Speaker enrollment and People management can evolve into:

- Unified ObjectBox-backed speaker profiles.
- Speaker merge/split.
- Better speaker labels across all historical transcripts.
- Per-speaker search and analytics.

### Transcript Knowledge Base

ObjectBox transcript storage and local LLM chat can evolve into:

- Global Q&A across all transcripts.
- Calendar-aware memory.
- Search plus semantic retrieval if embeddings are added.
- Action item extraction and follow-up tracking.

### Privacy And Compliance

Existing local-first design and HIPAA-friendly page can become:

- Clear local-only mode.
- Explicit model-download consent and storage controls.
- Encrypted backup/export.
- Configurable auto-delete audio policies.
- Better audit of what leaves device through reports/email/share.

### Cloud Account Sync

Supabase auth and profile infrastructure can eventually support:

- Cross-device subscription sync.
- Optional encrypted transcript sync.
- Account recovery.
- Team or clinician/admin modes.

### Better Background Reliability

`TranscriptionJobEntity` hints at:

- Persistent job queue.
- Resume/retry failed transcriptions.
- Chunk-level progress after restart.
- Background completion notifications.

## What Should Stay Stable

The most important product principle to preserve is local-first intelligence. The architecture is strongest when:

- Sensitive audio/transcript content stays on device by default.
- Cloud calls are explicit and purposeful.
- AI features work after models are installed.
- The UI makes long-running work visible and recoverable.

