# Transcript Project Knowledge Base

This folder is a NotebookLM-ready knowledge base for the `transcript` repository. It summarizes the current application, architecture, AI systems, local database, APIs, storage, flows, known issues, and inferred roadmap.

## Recommended Reading Order

1. [Project Overview](Project%20Overview.md)
2. [Current Features](Current%20Features.md)
3. [Architecture](Architecture.md)
4. [Data Flow](Data%20Flow.md)
5. [AI Systems](AI%20Systems.md)
6. [Database](Database.md)
7. [APIs](APIs.md)
8. [UI/UX](UI%20UX.md)
9. [Technical Decisions](Technical%20Decisions.md)
10. [Known Issues](Known%20Issues.md)
11. [Roadmap](Roadmap.md)
12. [Future Vision](Future%20Vision.md)

## What This Knowledge Base Covers

- Major product features and user workflows.
- Flutter app architecture and module boundaries.
- On-device AI systems: Whisper, diarization, speaker matching, local GGUF LLM.
- Prompt/system-prompt behavior for chat, summaries, Q&A, rewrite, and typo fixing.
- ObjectBox entities and Supabase tables/functions.
- Data flows for recording, import, YouTube transcripts, summarization, Q&A, billing, reports, and auto-email.
- Environment variables, external endpoints, dependencies, storage systems, and background workers.
- Current implementation state versus planned or inferred future work.

## Important Context

The app is local-first. Transcript content, audio processing, diarization, summaries, and transcript Q&A are designed to run primarily on-device. Cloud systems are used mainly for account eligibility, purchase verification, account deletion, model downloads, YouTube transcript fetching, reports, and optional transcript email delivery.

## Notes On Inference

Some roadmap and future-state items are inferred from comments, TODO-like placeholders, unused fields, duplicated modules, and partially implemented flows. Those sections are intentionally marked as inferred rather than confirmed product commitments.

