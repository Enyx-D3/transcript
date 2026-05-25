# Data Flow

## Recording-To-Transcript Flow

```mermaid
sequenceDiagram
  participant User
  participant Sheet as RecordSheet
  participant Rec as RecordingService
  participant OBX as ObjectBox
  participant BG as BackgroundTranscriber
  participant Compute as transcribeToResult
  participant Main as main callback

  User->>Sheet: Start recording
  Sheet->>Rec: start(targetSpeakers)
  Rec-->>Sheet: WAV path and runtime updates
  User->>Sheet: Stop recording
  Sheet->>OBX: create TranscriptEntity placeholder
  Sheet->>OBX: create TranscriptionJobEntity
  Sheet->>BG: start(wavPath, existingTranscriptId, lang, targetSpeakers)
  BG->>Compute: transcribeToResult()
  Compute-->>BG: TranscriptionResult
  BG-->>Main: sendDataToMain(type=transcribe_result)
  Main->>OBX: persistExistingTranscriptionFromResult()
  Main->>Main: normalize import paths if needed
  Main->>Main: delete audio if user enabled
  Main->>Main: auto-email if enabled
```

Why this flow exists:

The app creates a transcript row before transcription completes so the user can see progress immediately, navigate to the detail page, and recover from background processing delays.

## Import Audio/Video Flow

```mermaid
flowchart TD
  Pick["User picks file"] --> Path["Resolve readable path or stream copy"]
  Path --> Convert["Convert/extract to 16 kHz mono WAV"]
  Convert --> Placeholder["Create TranscriptEntity\nsourceType 2 audio or 3 video"]
  Placeholder --> Job["Create TranscriptionJobEntity"]
  Job --> Start["Set busy_transcribing=true\nStart BackgroundTranscriber"]
  Start --> Detail["Navigate to TranscriptDetailPage"]
  Start --> Pipeline["Diarization + Whisper pipeline"]
  Pipeline --> Persist["Persist turns into ObjectBox"]
```

## Transcription Compute Flow

```mermaid
flowchart TD
  Start["transcribeToResult"] --> Prefs["Read translate + diarization prefs"]
  Prefs --> Prep["preprocessWav16kMono"]
  Prep --> Duration["readWavDuration"]
  Duration --> DiarChoice{"Diarization enabled?"}
  DiarChoice -- No --> Single["Single Whisper pass"]
  Single --> SingleResult["One S1 turn"]
  DiarChoice -- Yes --> EnsureModels["ensureDiarizationModels"]
  EnsureModels --> Iso["Enhanced isolated embedding diarization"]
  Iso --> IsoOk{"Success?"}
  IsoOk -- No --> Fallback["In-thread embedding diarization"]
  IsoOk -- Yes --> Turns["Speaker turns"]
  Fallback --> Turns
  Turns --> Empty{"No turns?"}
  Empty -- Yes --> Single
  Empty -- No --> SliceLoop["Trim WAV per speaker turn"]
  SliceLoop --> Whisper["Whisper each slice"]
  Whisper --> Merge["Merge adjacent same speaker"]
  Merge --> Result["TranscriptionResult"]
```

## Summary Flow

```mermaid
sequenceDiagram
  participant Page as TranscriptSummaryPage
  participant OBX as ObjectBox
  participant LLM as LLMService isolate

  Page->>OBX: load transcript turns
  Page->>Page: build speaker-prefixed transcript text
  Page->>Page: set summary_busy_<id>=true
  Page->>LLM: summarizeTranscript(transcript, maxTokens)
  LLM->>LLM: split into chunks
  LLM->>LLM: summarize chunks silently
  LLM-->>Page: stream final merged summary
  Page->>OBX: upsert TranscriptSummaryEntity
  Page->>Page: set summary_busy_<id>=false
```

## Transcript Q&A Flow

```mermaid
sequenceDiagram
  participant User
  participant Page as TranscriptChatPage
  participant OBX as ObjectBox
  participant LLM as LLMService

  User->>Page: Ask question
  Page->>OBX: save user message
  Page->>OBX: save assistant placeholder
  Page->>OBX: load transcript turns
  Page->>LLM: qaOnTranscript(question, transcript)
  LLM-->>Page: stream answer
  Page->>OBX: throttle updates to placeholder
  Page->>OBX: save final cleaned answer
```

## YouTube Flow

```mermaid
flowchart TD
  URL["Pasted YouTube URL"] --> Extract["Extract video ID"]
  Extract --> API["youtube_transcript_api list/fetch"]
  API --> Tracks["Manual + auto tracks"]
  Tracks --> SaveTexts["saveYoutubeTranscripts"]
  SaveTexts --> Meta["YoutubeTranscriptMetaEntity"]
  SaveTexts --> TextRows["YoutubeTranscriptTextEntity rows"]
  Meta --> Transcript["Upsert TranscriptEntity sourceType=1"]
  Transcript --> Timeline["Timeline/Search/Favorites"]
```

## Billing Flow

```mermaid
sequenceDiagram
  participant UI as Paywall/Account
  participant IAP as InAppPurchase
  participant SVC as SubscriptionService
  participant Edge as Supabase Edge Function
  participant DB as Supabase Postgres

  UI->>SVC: buy(product) or restore()
  SVC->>IAP: purchase/restore/query past purchases
  IAP-->>SVC: PurchaseDetails
  SVC->>SVC: set local premium active
  SVC->>Edge: verify-play-subscription or verify-apple-subscription
  Edge->>Edge: verify token with Google/Apple
  Edge->>DB: lock purchase token to user
  Edge->>DB: update profiles entitlement fields
  Edge-->>SVC: ok/error
```

Why local unlock happens before server result:

The app prioritizes not blocking the purchaser if server verification is slow or temporarily failing. Remote eligibility still matters for account-level access and cross-device validation.

## Report And Auto Email Flow

- `AutoEmailService.sendIfEnabled` checks `pref_auto_email_transcript` and per-transcript sent flags.
- It builds transcript text and posts to `https://enyx.app/.netlify/functions/send-transcript-txt`.
- `ReportService.sendReport` posts report payloads to `https://enyx.app/.netlify/functions/send-report-transcript`.

Why this exists:

These flows support workflow automation and quality/support feedback without making cloud storage the primary transcript system.

