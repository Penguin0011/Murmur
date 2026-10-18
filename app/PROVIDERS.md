# Cloud provider verification

**Dated API research, not current provider terms or a setup guide.** Prices, model availability, retention policies and unauthenticated response observations below describe the dates stated, with later removals noted. Recheck the linked official documentation before configuring a provider. Current route selection is documented in [README.md](README.md#processing-routes-and-api-keys-wired-in); local deletion does not delete provider-held copies.

Verified on **2026-10-03** from official documentation, fetched that day. Tags: means stated in the cited official page that day; means strong indirect evidence (an archived official page, a third-party report, or an unauthenticated probe); means an inference that has not been checked. This initial research used unauthenticated probes (no key header), which record public error shapes; it does not summarize later live benchmark coverage.

## Summary and recommendation

| Route | Provider | Status on 2026-10-03 |
|---|---|---|
| Speech to text | Fireworks | **Removed 2026-10-07.** Deprecated upstream on 2026-06-10. |
| Speech to text | OpenRouter | **Removed 2026-10-07; deprecated upstream** (project owner's report, not re-verified here). Use **Custom Provider** settings for any OpenAI-compatible service. |
| Speech to text | Gemini (audio-in LLM) | `generateContent` with inline audio. **Implemented as an LLM transcriber** (`GeminiTranscriptionProvider`), with mitigations; see "Gemini audio transcription" below. It is not ASR. |
| Speech to text | Gemini 3.5 Transcribe | A dedicated ASR model, `gemini-3.5-transcribe`, documented only through the Beta Interactions API (`POST /v1beta/interactions`). **Implemented** as `GeminiTranscribeProvider`, per the user's decision of 2026-10-03, with `store` on: Google keeps each interaction 55 days (paid tier) or 1 day (free tier), and it can be deleted by API. See "Gemini 3.5 Transcribe" below. |
| Cleanup | Custom OpenAI-compatible API | Configurable base URL and model ID, `POST /v1/chat/completions`; may be hosted or a local server. Implemented as `OpenAICompatibleCleanupProvider`. |
| Cleanup | Gemini | `models.generateContent` is documented and "remains fully supported". Implemented. |

No Fireworks or OpenRouter client remains in `Providers.swift`, and neither is offered in Settings. Settings offer Gemini and any OpenAI-compatible endpoint for speech-to-text and cleanup; each stage has its own base URL, model and key.

## Fireworks (removed 2026-10-07)

The Fireworks client was deleted on 2026-10-07. Fireworks deprecated audio inference on 2026-06-10 (changelog entry "Audio inference and image generation deprecation"), so Murmur could not offer it. Its Keychain account is no longer read. Any other OpenAI-compatible transcription service is reached through **Custom Provider** settings.

The 2026-10-03 verification notes are in git history.

## Gemini API

Sources:
- generateContent reference: https://ai.google.dev/api/generate-content
- Interactions API overview (Beta; "The original generateContent API remains fully supported"): https://ai.google.dev/gemini-api/docs/interactions
- Audio understanding: https://ai.google.dev/gemini-api/docs/audio
- Models list: https://ai.google.dev/gemini-api/docs/models, https://ai.google.dev/gemini-api/docs/models/gemini-3.5-flash-lite and https://ai.google.dev/gemini-api/docs/models/gemini-3.8-flash
- Models REST reference: https://ai.google.dev/api/models
- Pricing: https://ai.google.dev/gemini-api/docs/pricing
- Rate limits: https://ai.google.dev/gemini-api/docs/rate-limits
- Troubleshooting: https://ai.google.dev/gemini-api/docs/troubleshooting
- Interactions error codes: https://ai.google.dev/gemini-api/docs/api-errors
- Terms, effective 2026-03-23: https://ai.google.dev/gemini-api/terms
- API key header: https://ai.google.dev/gemini-api/docs/api-key

Facts:
- **Endpoint:** `POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent`. Body: `systemInstruction` ("Currently, text only") plus `contents[].parts[].text`. Response text is in `candidates[0].content.parts[].text`, with `finishReason` (STOP, MAX_TOKENS, SAFETY, RECITATION, …). `promptFeedback.blockReason` means the prompt was blocked and no candidates are returned.
- **Why generateContent and not Interactions:** Interactions is Beta, defaults to server-side storage (`store=true`), and its schemas are subject to breaking changes. generateContent is stateless.
- **Auth header:** `x-goog-api-key: <key>`. The implementation never puts the key in the URL query string.
- **Model IDs:** `gemini-3.5-flash-lite` (stable, updated July 2026) is the default for cleanup, and `gemini-3.8-flash` (stable, updated September 2026) is an alternative. Both accept text, image, video, audio and PDF input and produce text. Google limits the 2.5 models to existing users.
- **Pricing (paid tier, per 1M tokens):** `gemini-3.5-flash-lite` costs $0.30 input (text, image, video and audio) and $2.50 output. `gemini-3.8-flash` costs $0.75 input and $3.75 output through 2026-12-31, then $1.50 and $7.50. A free tier exists.
- **Data use:** on the unpaid tier, Google uses submitted content to improve products and "human reviewers may read, annotate, and process your API input and output … Do not submit sensitive, confidential, or personal information to the Unpaid Services." On the paid tier, prompts are not used to improve products; they are logged "for a limited period of time" for abuse detection. **The disclosure must tell users that a free-tier key exposes dictation to human review.**
- **Audio transcription:** see "Gemini audio transcription" below.
- **Errors:** 429 `RESOURCE_EXHAUSTED` and 503 `UNAVAILABLE` are retryable; 400, 402 and 403 are not. The Interactions error table lists 401 authentication, 402 payment_required (Prepay credits depleted), 403 permission_denied, 404 model_not_found, 429 rate_limit_exceeded or quota_exceeded ("daily quota"), 499 cancelled, 500, 503 and 504. For generateContent, the observed unauthenticated body is the Google RPC shape `{"error":{"code":403,"message":"...","status":"PERMISSION_DENIED"}}`. Google RPC errors usually carry `RetryInfo.retryDelay` (for example `"30s"`) in `error.details`. An invalid key is commonly reported as 400 `INVALID_ARGUMENT` with reason `API_KEY_INVALID`, not 401. The classifier handles both.
- **Rate limits:** RPM, TPM and RPD limits apply per project, not per key. RPD resets at midnight Pacific. Spend caps return 429 `RESOURCE_EXHAUSTED`.
- **Payload limit:** 20 MB total request size for inline data. The 413 status for generateContent is not documented.
- **Validation call:** `GET https://generativelanguage.googleapis.com/v1beta/models?pageSize=1` (models.list, which costs no tokens).

## Gemini audio transcription

Sources (fetched 2026-10-03):
- Audio understanding (last updated 2026-09-23): https://ai.google.dev/gemini-api/docs/audio
- Audio transcription with Gemini 3.5 Transcribe (last updated 2026-09-23): https://ai.google.dev/gemini-api/docs/transcribe
- Model pages: https://ai.google.dev/gemini-api/docs/models/gemini-3.5-transcribe and https://ai.google.dev/gemini-api/docs/models/gemini-3.5-flash-lite
- generateContent reference (GenerationConfig, Blob, FinishReason, BlockReason): https://ai.google.dev/api/generate-content
- Structured outputs: https://ai.google.dev/gemini-api/docs/structured-output
- Pricing: https://ai.google.dev/gemini-api/docs/pricing

Facts:
- **Limits:** "Maximum request size is 20 MB total (including prompts and all files)"; above that, use the Files API. The limit is 9.5 hours of audio per prompt. Audio is downsampled to 16 Kbps, and multi-channel audio is combined into one channel. Inline audio is base64-encoded, so `GeminiTranscriptionProvider` caps raw audio at about 14.95 MB and rechecks the encoded body against 20 MB.
- **MIME types:** `audio/wav`, `audio/mp3`, `audio/aiff`, `audio/aac`, `audio/ogg`, `audio/flac`, `audio/mpeg`, `audio/m4a`, `audio/l16`, `audio/opus`, `audio/alaw`, `audio/mulaw`, `audio/webm`. Other types are rejected locally.
- **Token cost:** "32 tokens per second of audio (1 minute = 1,920 tokens)". At the paid input price for `gemini-3.5-flash-lite` ($0.30 per 1M tokens), one minute of audio costs about $0.00058 in input tokens. Output tokens cost $2.50 per 1M on top of that.
- **Request shape:** `contents[].parts[]` takes `inlineData: {mimeType, data}`, with `data` in base64. `systemInstruction` is text only.
- **Structured output:** the `gemini-3.5-flash-lite` model page lists "Structured outputs: Supported". The generateContent reference marks `responseSchema` and `_responseJsonSchema` "Deprecated. Use responseFormat instead". `responseFormat.text` takes `mimeType` (`APPLICATION_JSON`) and a JSON `schema`, and `additionalProperties` is among the supported schema keywords. The structured-output guide says output "is syntactically correct JSON", but values must still be validated. Whether generateContent honours `responseFormat` for this model has not been tested with a key. For the live test, `schemaStyle = .legacyResponseSchema` sends the deprecated `responseMimeType` plus `responseSchema` instead. Parsing is strict either way.
- **Blocks:** `promptFeedback.blockReason` (SAFETY, OTHER, BLOCKLIST, PROHIBITED_CONTENT, IMAGE_SAFETY) means "the prompt was blocked and no candidates are returned". The finish reasons SAFETY, RECITATION, LANGUAGE, BLOCKLIST, PROHIBITED_CONTENT and SPII stop generation. All of these map to `contentBlocked`, and MAX_TOKENS maps to `malformedResponse`.
- **Why it is an LLM, not ASR:** the audio-understanding page sends users who need "dedicated speech to text models" to Google Cloud Speech-to-Text. The output is generated text, so it can answer or obey spoken requests, hallucinate text for silence, and tidy wording.
- **Mitigations implemented:**
  - temperature 0;
  - a system instruction that the audio is data to transcribe verbatim;
  - a `{"transcript": string}` schema with `additionalProperties: false`;
  - strict parsing, so non-JSON, code fences, prose or extra fields are `malformedResponse`;
  - `shouldSkipForSilence(peakLevel:durationSeconds:)` for the caller, defaulting to a -40 dBFS peak and a 0.3 s minimum;
  - `LLMTranscriptCheck.answerSuspected`. This heuristic cannot prove that the model answered, because there is no raw ASR text to compare against.
- **Gemini 3.5 Transcribe:** Google describes `gemini-3.5-transcribe` as "a speech-to-text model".
  - Features: a `verbatim` mode (the default, which keeps fillers and false starts), a `smart` mode, language hints, and up to 1,000 `custom_vocabulary` terms. Requests can be up to 1 hour long.
  - Price: $2.00 per 1M input audio tokens and $12.00 per 1M output tokens on the paid tier; Google estimates about $0.005/min. Free-tier content is "used to improve our products".
  - Endpoint: every documented example uses the Interactions API (`POST https://generativelanguage.googleapis.com/v1beta/interactions`, `generation_config.transcription_config`), and most use a Files API URI. Interactions is Beta and stores interactions on the server by default (see above).
  - Implemented as `GeminiTranscribeProvider`; full facts in "Gemini 3.5 Transcribe" below. Whether `gemini-3.5-transcribe` also accepts generateContent is not documented.
  - The generateContent `GenerationConfig` also lists `audioTranscriptionConfig` ("Config for audio transcription (speech recognition)"). No guide covers using it outside the Live API.
- **Data use:** the same terms apply as for cleanup. The free tier allows human review, so the disclosure says so, and it says that audio leaves this Mac to Google.

## Gemini 3.5 Transcribe

**User decision, 2026-10-03:** use `gemini-3.5-transcribe` for cloud STT and accept that Google stores Interactions API requests. Implemented as `GeminiTranscribeProvider` in `Providers.swift`.

Sources (all fetched 2026-10-03, as the `.md.txt` versions Google publishes next to each page):
- Transcribe guide: https://ai.google.dev/gemini-api/docs/transcribe
- Model page (latest update August 2026): https://ai.google.dev/gemini-api/docs/models/gemini-3.5-transcribe
- Interactions overview, including "Data storage and retention": https://ai.google.dev/gemini-api/docs/interactions
- Interactions API reference (v1beta) and its OpenAPI spec: https://ai.google.dev/api/interactions-api and https://ai.google.dev/static/api/interactions.openapi.json
- Interactions API reference (v1): https://ai.google.dev/api/interactions-api-v1
- Interactions audio guide (inline audio): https://ai.google.dev/gemini-api/docs/interactions/audio
- Interactions error codes: https://ai.google.dev/gemini-api/docs/api-errors
- Breaking changes (May 2026, `Api-Revision`): https://ai.google.dev/gemini-api/docs/interactions-breaking-changes-may-2026
- Pricing: https://ai.google.dev/gemini-api/docs/pricing#gemini-3.5-transcribe
- Files API: https://ai.google.dev/gemini-api/docs/files
- Terms (effective 2026-03-23): https://ai.google.dev/gemini-api/terms

Facts:
- **Endpoint:** `POST https://generativelanguage.googleapis.com/v1beta/interactions` (CreateInteraction). The reference also lists a stable `/v1/interactions`, but the v1 reference does not mention `transcription_config`, and every transcribe example uses v1beta, so the provider uses v1beta.
- **Auth:** header `x-goog-api-key: <key>`, as in every REST example; the OpenAPI security scheme says "Gemini API key sent as x-goog-api-key".
- **Request, inline audio:** `{"model": "gemini-3.5-transcribe", "input": [{"type": "audio", "data": "<base64>", "mime_type": "audio/wav"}], "generation_config": {"transcription_config": {...}}, "store": true}`. `AudioContent` has `data` ("format": "byte") or `uri`, plus `mime_type`. The audio guide shows `data` with base64 "for small audio files under 20MB total request size". No transcribe example uses inline `data` (they all use a Files API `uri`), so inline audio with *this model* is not shown.
- **Request, file upload:** upload with the Files API, then pass `{"type": "audio", "uri": "<file uri>", "mime_type": ...}`. Files are kept 48 hours. The guide recommends the Files API "for files longer than a few seconds". Murmur clips are under 2 minutes (about 3.8 MB as 16 kHz mono 16-bit WAV), far under the 20 MB inline limit, so the provider sends inline audio and does not upload files. That avoids a second stored copy and a second request.
- **Transcription fields** (`generation_config.transcription_config`):
  - `mode`: `{"type": "verbatim"}` (the default) or the string `"smart"`. Verbatim keeps fillers, repetitions and false starts. Smart removes disfluencies, resolves self-corrections and formats lists. The provider sends `{"type": "verbatim"}` explicitly; `mode = .smart` is available.
  - `language_codes`: BCP-47 codes; omitted or empty means automatic detection. The supported-language table lists regional codes such as `en-US`, `en-GB` and `en-IN`, not a bare `en`. The provider sends the payload's code as given (`["en"]` by default, as asked), and `languageCodes` overrides it (for example `["en-US"]`).
  - `custom_vocabulary`: an array of up to 1,000 terms (best results with up to 100). It cannot be combined with diarization or word timestamps. The provider splits `AudioPayload.vocabularyHint` on newlines and commas, drops control characters and duplicates, caps the list at 1,000, and sends no diarization or timestamp fields.
  - Deprecated in the spec, not sent: `language_hints`, `adaptation_phrases`, and top-level `diarization_mode` and `timestamp_granularities`.
- **Response:** an `Interaction` with `id`, `status` and `steps[]`. The transcript is in `steps[].content[]` blocks of `"type": "text"` inside `"type": "model_output"` steps. The SDK's `output_text` joins the last run of consecutive text blocks; the parser does the same. The guide's example `id` is `interactions/abc123xyz`, while the reference examples use `v1_Chd...`; both forms are accepted, and the `interactions/` prefix is stripped when building GET and DELETE URLs.
- **Status values:** `in_progress`, `requires_action`, `completed`, `failed`, `cancelled`, `incomplete`, `budget_exceeded` (deprecated) and `queued`. Failures carry `errors[]` of `{code, message}`, where `code` is "a URI that identifies the error type". Handling: `completed` gives the text (a `steps` array with no text gives "", treated as silence); `in_progress` and `queued` are polled; `failed` with a blocked code gives `contentBlocked`, otherwise `server`; `cancelled` gives `server`; everything else gives `malformedResponse`, so partial text is never inserted.
- **Sync or async:** `background` defaults to off ("Whether to run the model interaction in the background"), and the reference examples return `"status": "completed"` from the create call. Nothing says a transcription answers `in_progress`. To be safe, an `in_progress` or `queued` answer is polled with `GET /v1beta/interactions/{id}`, which needs the interaction to be stored. Polling uses the same id and never sends a second `POST`. It is bounded by `overallDeadline` (90 s), `maxPolls` (60) and a 1 s interval that grows ×1.5 up to 4 s. Transient GET failures (network, timeout, 429 and 5xx) are retried by GET within the deadline. Task cancellation stops it. The provider never sets `background` and never calls `/cancel`, which "only applies to background interactions".
- **Limits:** up to 1 hour of audio per request (30 minutes with diarization or timestamps). The inline request limit is 20 MB total. The Files API page says to use files above 100 MB, which conflicts with the 20 MB figure; the provider uses the stricter 20 MB (about 14.95 MB of raw audio after base64). MIME types: the same 13 as the audio guide (`audio/wav`, `audio/mp3`, `audio/aiff`, `audio/aac`, `audio/ogg`, `audio/flac`, `audio/mpeg`, `audio/m4a`, `audio/l16`, `audio/opus`, `audio/alaw`, `audio/mulaw`, `audio/webm`).
- **`store`:** "Input only. Whether to store the response and request for later retrieval." It defaults to true: "By default, the API stores all Interaction objects (`store=true`)". `store=false` is incompatible with `background=true` and with `previous_interaction_id`. The provider sends `"store": true` explicitly, per the user's decision, and exposes `store` as a property.
- **Retention:** "Paid Tier: The system retains interactions for **55 days**. Free Tier: The system retains interactions for **1 day**." After that, "your data will be deleted automatically".
- **Deletion:** "You can delete stored interactions at any time using the delete method … You can only delete interactions if you know the interaction ID." The call is `DELETE https://generativelanguage.googleapis.com/v1beta/interactions/{id}`, and "If successful, the response is empty". `deleteStored(interactionID:)` implements it and treats 404 as already deleted. Separately, the paid-tier terms say Google "logs prompts and responses for a limited period of time" for abuse detection. Whether deleting an interaction also removes that log is not documented.
- **Data use:** Free tier: content is "used to improve our products", and human reviewers may read it. Paid tier: not used to improve products. The disclosure says so.
- **Pricing (paid tier):** $2.00 per 1M input audio tokens ($0.003/min) and $12.00 per 1M output tokens ($0.002/min), about $0.005/min blended at 25 audio tokens per second. The free tier is free of charge.
- **generateContent:** the docs are silent. The transcribe guide, the model page and pricing only show the Interactions API (plus `gemini-3.5-transcribe-live` on the Live API). The model is also absent from the OpenAPI `ModelOption` enum, which allows unknown values.
- **Errors (documented):** `{"error": {"code": "<snake_case>", "message": "..."}}` with the HTTP status. Codes: 400 `invalid_request`, `failed_precondition` and `parameter_unknown`; 401 `authentication`; 402 `payment_required`; 403 `permission_denied`; 404 `not_found` and `model_not_found`; 409 `already_exists` and `aborted`; 416 `out_of_range`; 429 `rate_limit_exceeded`, `quota_exceeded` (daily) and `too_many_requests`; 499 `cancelled`; 500 `api_error`; 501 `unimplemented`; 503 `service_unavailable`; 504 `deadline_exceeded`. Blocked codes: `safety`, `recitation`, `language`, `prohibited_content`, `spii`, `blocklist`, `content_blocked`, and the `image_*` variants.
- **Errors (observed without a valid key, 2026-10-03):** Google's front end answers before the Interactions layer, in the Google RPC shape. With no key: 403 `PERMISSION_DENIED` ("Method doesn't allow unregistered callers"). With a fake key: 400 `INVALID_ARGUMENT` with reason `API_KEY_INVALID`. **On `POST` and `GET /v1beta/interactions` the body is wrapped in a one-element JSON array** (`[{"error": {...}}]`); on `DELETE` it is a plain object. `ErrorBody` now unwraps a one-object array, so the bad key classifies as `authentication`, not `rejected`.
- **`Api-Revision`:** the audio guide sends `Api-Revision: 2026-05-20`. The breaking-changes page says that, from June 8, 2026, the legacy schema is removed and the header is ignored. The provider does not send it.
- **Validation call:** `GET /v1beta/models?pageSize=1` (models.list, which costs no tokens). It proves the key, not access to `gemini-3.5-transcribe`.
- **Interaction ids:** `transcribeDetailed(_:onInteractionCreated:)` returns `GeminiTranscribeResult(text:interactionID:stored:)` and reports the id once through the callback. The provider persists nothing. Keeping ids (for example, to offer "delete from Google" or to delete after a successful insert) is the integrator's decision.

## Local OpenAI-compatible servers

Sources (fetched 2026-10-03):
- Ollama OpenAI compatibility: https://docs.ollama.com/api/openai-compatibility
- Ollama list local models: https://docs.ollama.com/api/tags
- LM Studio OpenAI compatibility: https://lmstudio.ai/docs/developer/openai-compat
- LM Studio server settings and authentication: https://lmstudio.ai/docs/developer/core/server/settings and https://lmstudio.ai/docs/developer/core/authentication
- llama.cpp server README: https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md
- vLLM quickstart (OpenAI-compatible server): https://github.com/vllm-project/vllm/blob/main/docs/getting_started/quickstart.md

| Server | Default base | Chat | Model list | Key |
|---|---|---|---|---|
| Ollama | `http://localhost:11434/v1/` | `POST /v1/chat/completions` | `GET /v1/models`. The native `GET /api/tags` returns `{"models":[{"name","model","modified_at","size","digest","details"}]}`. | "Required but ignored": any value works for OpenAI clients. |
| LM Studio | `http://localhost:1234/v1` | `POST /v1/chat/completions` | `GET /v1/models` | Off by default. With "Require Authentication" on, send `Authorization: Bearer <token>`. A "Serve on Local Network" toggle exists. |
| llama.cpp `llama-server` | `--host` 127.0.0.1, `--port` 8080 | `POST /v1/chat/completions` | `GET /v1/models`. The id defaults to the model path or `--alias`. | `--api-key`, default none. `GET /health` returns 503 while the model loads. |
| vLLM | `http://localhost:8000` | `POST /v1/chat/completions` | `GET /v1/models` | `--api-key` or `VLLM_API_KEY`, checked "in the header". Sent as a Bearer token. |

Facts and choices:
- **Model discovery:** all four document `GET /v1/models` in the OpenAI list form `{"object":"list","data":[{"id":...}]}`. `discoverModels()` therefore uses `/v1/models`. It calls Ollama's `/api/tags` only when `/v1/models` returns 404, as older Ollama builds may. Both calls go to the same host and carry no transcript.
- **Base URL:** the URL may be given with or without `/v1`. The provider strips a trailing `/v1` and builds `{base}/v1/chat/completions`.
- **On-device rule**:
  - On-device: only `localhost`, strict dotted-decimal 127.0.0.0/8, and IPv6 `::1` in any spelling, with or without brackets.
  - Everything else is disclosed as "the transcript leaves this Mac to <host>". This includes LAN, `.local` and private IPs, as well as spellings that may reach loopback (`127.1`, `2130706433`, `localhost.`, `::ffff:127.0.0.1`). Over-disclosure is the safe direction.
  - Rejected: `0.0.0.0` and `::` (listen addresses, not destinations), schemes other than http and https, user info, queries, fragments and percent-encoded hosts.
  - Plain HTTP to a non-loopback host adds an unencrypted-connection warning. The current client omits custom API keys on such connections, while audio/transcript content remains exposed to the network path.
- **Redirects:** local servers' redirects are not followed; a 3xx becomes `rejected`. A server therefore cannot forward the transcript to a host the disclosure did not name. This was checked live on Linux against a local test server. It has not been checked on macOS.
- **Connection refused:** `URLError.cannotConnectToHost` becomes `serverNotRunning(address:)`, for example "No local model server is running at localhost:11434". The address comes from the configured URL and never includes the path, key or transcript. This was checked live on Linux.
- **Timeout:** 120 s by default, because a cold model load can be slow, clamped to 1–300 s.

## OpenRouter (removed 2026-10-07)

The OpenRouter speech-to-text and cleanup clients were deleted on 2026-10-07. OpenRouter is deprecated upstream, as reported by the project owner on that date; this document did not re-verify the deprecation. Users who want OpenRouter, or any other OpenAI-compatible service, enter its base URL, model ID and key in the **Custom Provider** settings. Murmur still reads the legacy OpenRouter Keychain account once, during migration, and copies that key to the custom endpoint.

The verification notes from 2026-10-03 are in the git history of this file, before the removal commit.

## Error classification used by `Providers.swift`

| ProviderError | Triggers |
|---|---|
| `authentication` | 401 or 403 on any provider; Gemini 400 whose status is `INVALID_ARGUMENT` and whose message or reason mentions an API key (including Google's one-element array error bodies) |
| `quota` | 402 on any provider; Gemini 429 whose body says the daily quota or billing limit is reached (`quota_exceeded`, "quota" plus "per day", or "billing") |
| `rateLimited(retryAfter)` | other 429s; `Retry-After` (seconds or HTTP-date) or Gemini `RetryInfo.retryDelay` |
| `payloadTooLarge` | 413; a local size check before upload (20 MB total request for Gemini, so about 14.95 MB of raw audio for Gemini STT) |
| `timeout` | 408, 504, `URLError.timedOut`, or the explicit request timeout |
| `network` | offline, DNS or connection failures (cloud); DNS or other failures for a local server |
| `serverNotRunning(address)` | local server only: connection refused (`URLError.cannotConnectToHost`) |
| `server` | 5xx (other than 504) and 520–530; an error object inside an HTTP 200 on the chat format |
| `malformedResponse` | 2xx whose body is not parseable or has no text; Gemini empty candidates or MAX_TOKENS; Gemini STT text that is not exactly `{"transcript": string}` |
| `contentBlocked` | Gemini `promptFeedback.blockReason` or a safety finish reason; Gemini 3.5 Transcribe `status: failed` with a documented blocked code; `content_filter` finish |
| `rejected` | other 4xx (bad request, model not found); any 3xx (redirects are not followed for local servers) |

Gemini 3.5 Transcribe also maps `status: failed` (other codes) and `cancelled` to `server`, `incomplete`, `requires_action` and unknown statuses to `malformedResponse`, and a polling deadline or `maxPolls` to `timeout`.

`cancelled` is separate, and the caller should treat it as a user action rather than a provider fault.

User messages contain only the provider name, the category and a retry hint. They never contain the response body, the key, or transcript text.

## Not verified

- Gemini's 413 behaviour, the exact status for an invalid key, and `RetryInfo` presence on generateContent.
- Gemini STT with a real key: whether generateContent honours `responseFormat`, how often the model answers, tidies or hallucinates, and the right silence threshold.
- Whether `gemini-3.5-transcribe` works through generateContent (the docs are silent).
- Gemini 3.5 Transcribe with a real key. Specifically:
  - whether inline `data` audio works with this model (every transcribe example uses a file `uri`);
  - whether a bare `en` is accepted in `language_codes` (the table lists `en-US`);
  - whether short clips always come back `completed` from the create call;
  - which id form the server returns (`interactions/…` or `v1_…`);
  - what a silent clip returns;
  - whether a 404 is returned for an expired or deleted interaction;
  - whether deleting an interaction also removes Google's paid-tier abuse logs.
- Local servers: no real Ollama, LM Studio, llama-server or vLLM was run. Request and response shapes come from their docs. Transport behaviour was checked against a Python stand-in on Linux.
