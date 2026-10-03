# Cloud provider verification

Verified on **2026-10-03** from official documentation, fetched that day. Tags: [Certain] means stated in the cited official page that day; [Likely] means strong indirect evidence (an archived official page, a third-party report, or an unauthenticated probe); [Guessing] means an inference that has not been checked. No call has been made with a real API key. The only live requests were unauthenticated probes (no key header), which record public error shapes. [Certain]

## Summary and recommendation

| Route | Provider | Status on 2026-10-03 |
|---|---|---|
| Speech to text | Fireworks | **Not usable as the launch STT provider.** Fireworks' changelog says "Audio inference and image generation are deprecated" (2026-06-10). The transcription guide and API reference now return 404, and audio pricing no longer appears on the pricing page. [Certain] Unauthenticated probes on 2026-10-03: `audio-turbo.api.fireworks.ai` and `audio-turbo.us-virginia-1.direct.fireworks.ai` returned `503 no healthy upstream`, and `audio-prod.api.fireworks.ai` returned 401. [Certain] |
| Speech to text | OpenRouter | **Documented and current.** `POST https://openrouter.ai/api/v1/audio/transcriptions` accepts OpenAI-style multipart. [Certain] Recommended as the launch STT route, pending a live test with a real key. [Likely] |
| Speech to text | Gemini | Possible only as audio-in prompting ("Generate a transcript of the speech"). There is no dedicated transcription endpoint. The docs send users who need dedicated speech to text to Google Cloud Speech-to-Text. [Certain] This route is not implemented. |
| Cleanup | Gemini | `models.generateContent` is documented and "remains fully supported". [Certain] Implemented. |
| Cleanup | OpenRouter | `POST https://openrouter.ai/api/v1/chat/completions`. [Certain] Implemented. |

`Providers.swift` still includes the Fireworks STT client, because the PRD named it and the endpoint may come back. It is marked deprecated and unverified, and its base URL is configurable. The integration lead should not offer it in settings unless a live test with a real key passes. [Certain]

## Fireworks

Sources:
- Changelog, 2026-06-10 entry "Audio inference and image generation deprecation": https://docs.fireworks.ai/updates/changelog
- Documentation index (no transcription page listed): https://docs.fireworks.ai/llms.txt
- Archived Speech to Text guide, Wayback snapshot of 2026-02-15: https://web.archive.org/web/20260215102338/https://docs.fireworks.ai/guides/querying-asr-models
- Error codes: https://docs.fireworks.ai/guides/inference-error-codes
- Rate limits: https://docs.fireworks.ai/serverless/rate-limits
- Data handling: https://docs.fireworks.ai/guides/security_compliance/data_handling
- List Models: https://docs.fireworks.ai/api-reference/list-models and https://docs.fireworks.ai/faq-new/models-inference/how-to-check-if-a-model-is-available-on-serverless
- Third-party reports, not official: https://github.com/BerriAI/litellm/issues/30916 (2026-06-21) and https://github.com/TypeWhisper/typewhisper-win/pull/481 (2026-09-18)

Facts:
- **Is there a true transcription endpoint?** There was one: `POST {base}/v1/audio/transcriptions`, OpenAI-compatible multipart. The archived guide lists model `whisper-v3` on base `https://audio-prod.api.fireworks.ai` and model `whisper-v3-turbo` on base `https://audio-turbo.api.fireworks.ai`. [Likely, from the archived official page] Audio inference has been deprecated since 2026-06-10. [Certain] Current docs have no transcription reference. [Certain]
- One third-party report says `api.fireworks.ai/inference/v1/audio/transcriptions` returns 401 with keys that work for chat. [Likely] Another says Whisper V3 Turbo still worked in September 2026. [Likely] My unauthenticated probe on 2026-10-03 found both turbo hosts returning 503. [Certain] Whether turbo works with a real key today is **unverified**.
- **Model IDs:** `whisper-v3` and `whisper-v3-turbo`, from the archived page only. [Likely] There is no current official model ID for audio.
- **Auth header:** `Authorization: Bearer <FIREWORKS_API_KEY>`. [Certain for the Fireworks API in general; Likely for the audio hosts]
- **Audio formats and size:** the archived guide says "Supports files up to 1GB in formats like MP3, FLAC, and WAV". [Likely] The current limit is unknown.
- **Pricing:** audio pricing no longer appears on https://fireworks.ai/pricing. **Unverified.**
- **Data retention:** "Fireworks does not log or store prompt or generation data for any open models, without explicit user opt-in"; data lives in volatile memory for the duration of the request, and metadata (such as token counts) is logged. [Certain] Whether this policy covered the audio hosts is not stated. [Guessing]
- **Error codes** (official table): 400 bad request; 401 invalid API key; 402 payment required ("exceeded usage limits"); 403 authentication issues; 404 model not found or not deployed; 408 timeout; 412 account suspended; 413 payload too large; 429 rate limited; 500, 502, 503 and 504 server-side; 520 unknown. [Certain]
- **Rate-limit headers:** adaptive TPM limits are reported in `X-Ratelimit-Limit-Tokens-*` headers. A `Retry-After` header on 429 is not documented. [Certain about the headers; Retry-After unverified]
- **Error body shape**, observed without a key on `api.fireworks.ai`: `{"error":{"message":"...","param":null,"code":"UNAUTHORIZED","type":"error"},"request_id":"..."}`. On the audio host it was `{"error":{"object":"error","type":"unauthorized","message":"Unauthorized"}}`. [Certain, as observed]
- **Validation call:** `GET https://api.fireworks.ai/v1/accounts/fireworks/models?pageSize=1` with Bearer auth is the documented List Models call. [Certain] It proves the key works on the general API, not that audio is available. [Certain]

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
- **Endpoint:** `POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent`. [Certain] Body: `systemInstruction` ("Currently, text only") plus `contents[].parts[].text`. Response text is in `candidates[0].content.parts[].text`, with `finishReason` (STOP, MAX_TOKENS, SAFETY, RECITATION, …). `promptFeedback.blockReason` means the prompt was blocked and no candidates are returned. [Certain]
- **Why generateContent and not Interactions:** Interactions is Beta, defaults to server-side storage (`store=true`), and its schemas are subject to breaking changes. generateContent is stateless. [Certain about the documented facts; the choice is mine]
- **Auth header:** `x-goog-api-key: <key>`. [Certain] The implementation never puts the key in the URL query string.
- **Model IDs:** `gemini-3.5-flash-lite` (stable, updated July 2026) is the default for cleanup, and `gemini-3.8-flash` (stable, updated September 2026) is an alternative. Both accept text, image, video, audio and PDF input and produce text. [Certain] Google limits the 2.5 models to existing users. [Certain]
- **Pricing (paid tier, per 1M tokens):** `gemini-3.5-flash-lite` costs $0.30 input (text, image, video and audio) and $2.50 output. `gemini-3.8-flash` costs $0.75 input and $3.75 output through 2026-12-31, then $1.50 and $7.50. A free tier exists. [Certain]
- **Data use:** on the unpaid tier, Google uses submitted content to improve products and "human reviewers may read, annotate, and process your API input and output … Do not submit sensitive, confidential, or personal information to the Unpaid Services." On the paid tier, prompts are not used to improve products; they are logged "for a limited period of time" for abuse detection. [Certain] **The disclosure must tell users that a free-tier key exposes dictation to human review.**
- **Audio transcription:** possible by prompting with audio. Inline audio is limited to 20 MB total request size; use the Files API for larger files. Formats: WAV, MP3, AIFF, AAC, OGG, FLAC, MPEG, M4A, L16, Opus, ALAW, MULAW and WebM. Audio counts as 32 tokens per second, up to 9.5 hours per prompt. [Certain] There is no dedicated STT endpoint, and output is LLM-generated, so it can paraphrase or obey speech content. [Likely] Not implemented.
- **Errors:** 429 `RESOURCE_EXHAUSTED` and 503 `UNAVAILABLE` are retryable; 400, 402 and 403 are not. [Certain] The Interactions error table lists 401 authentication, 402 payment_required (Prepay credits depleted), 403 permission_denied, 404 model_not_found, 429 rate_limit_exceeded or quota_exceeded ("daily quota"), 499 cancelled, 500, 503 and 504. [Certain, for Interactions] For generateContent, the observed unauthenticated body is the Google RPC shape `{"error":{"code":403,"message":"...","status":"PERMISSION_DENIED"}}`. [Certain, as observed] Google RPC errors usually carry `RetryInfo.retryDelay` (for example `"30s"`) in `error.details`. [Likely; not shown in current docs] An invalid key is commonly reported as 400 `INVALID_ARGUMENT` with reason `API_KEY_INVALID`, not 401. [Likely; not in current docs] The classifier handles both.
- **Rate limits:** RPM, TPM and RPD limits apply per project, not per key. RPD resets at midnight Pacific. Spend caps return 429 `RESOURCE_EXHAUSTED`. [Certain]
- **Payload limit:** 20 MB total request size for inline data. [Certain] The 413 status for generateContent is not documented. [Guessing]
- **Validation call:** `GET https://generativelanguage.googleapis.com/v1beta/models?pageSize=1` (models.list, which costs no tokens). [Certain]

## OpenRouter

Sources:
- Documentation index: https://openrouter.ai/docs/llms.txt
- Chat completions: https://openrouter.ai/docs/api/api-reference/chat/create-a-chat-completion
- Speech-to-Text: https://openrouter.ai/docs/guides/overview/multimodal/stt
- Errors: https://openrouter.ai/docs/api_reference/errors-and-debugging
- Limits: https://openrouter.ai/docs/api_reference/limits
- Current key: https://openrouter.ai/docs/api/api-reference/api-keys/get-current-api-key
- Data collection: https://openrouter.ai/docs/guides/privacy/data-collection
- Provider logging: https://openrouter.ai/docs/guides/privacy/provider-logging
- ZDR: https://openrouter.ai/docs/guides/features/zdr
- Live public model catalogue, no key needed: https://openrouter.ai/api/v1/models and https://openrouter.ai/api/v1/models?output_modalities=transcription

Facts:
- **Chat endpoint:** `POST https://openrouter.ai/api/v1/chat/completions` with `Authorization: Bearer <key>` and the OpenAI-style `messages` array. The response text is in `choices[0].message.content`. [Certain]
- **Cleanup model IDs present in the live catalogue on 2026-10-03:** `google/gemini-3.5-flash-lite` (default; $0.30 in and $2.50 out per 1M tokens), `google/gemini-3.8-flash`, `openai/gpt-5.4-mini`, `~anthropic/claude-haiku-latest`. [Certain, as listed] The catalogue changes, so the model ID is configurable.
- **STT endpoint:** `POST https://openrouter.ai/api/v1/audio/transcriptions`. It accepts JSON (`input_audio.data` base64 plus `format`) or OpenAI-style multipart with fields `file`, `model`, `language`, `temperature`, `response_format` (`json` or `verbose_json`) and `timestamp_granularities`. `prompt` is "accepted but ignored". [Certain] The response is `{"text": "...", "usage": {"seconds": …, "cost": …}}`. [Certain]
- **STT limits:** "Multipart uploads are limited to 25 MB." Upstream providers time out after 60 seconds per request. Formats include wav, mp3, flac, m4a, ogg, webm and aac. [Certain]
- **STT model IDs in the live catalogue:** `openai/whisper-large-v3-turbo` (default), `openai/whisper-large-v3`, `openai/whisper-1`, `openai/gpt-4o-mini-transcribe`, `nvidia/parakeet-tdt-0.6b-v3`, and others. [Certain, as listed] Pricing, per the catalogue's `prompt` field: `whisper-large-v3-turbo` 0.00000333 and `whisper-1` 0.0001. [Certain as listed] I read the unit as USD per second of audio, because whisper-1 then works out to $0.006/min. [Likely]
- **Errors:** the body is `{"error":{"code":<int>,"message":"...","metadata":{...}}}`. Status codes: 400, 401 (invalid credentials), 402 (insufficient credits), 403 (guardrail or moderation), 408, 429 (rate limited), 502 (model down) and 503 (no provider meets routing requirements). [Certain] **Errors raised after generation starts return HTTP 200 with an error in the body**, so the parser checks for an `error` object even on 200. [Certain] `Retry-After` is sent on 429 and 503, and on 402 when the in-flight budget is exceeded. [Certain]
- **Data retention:** OpenRouter "does not store your prompts or responses" unless the user opts into logging. Metadata is stored. Upstream providers have their own retention. The per-request `"provider": {"zdr": true}` routes only to Zero Data Retention endpoints. [Certain] `Providers.swift` exposes `zeroDataRetention` (default `false`). Turning it on can make a model return 503 when no ZDR endpoint exists. [Likely]
- **Payload limit for chat:** not stated as a byte limit. 413 is in the general HTTP list but not described. [Guessing]
- **Validation call:** `GET https://openrouter.ai/api/v1/key` (current key info, which costs no tokens). [Certain] Without a key it returned `{"error":{"message":"No cookie auth credentials found","code":401}}`. [Certain, as observed]

## Error classification used by `Providers.swift`

| ProviderError | Triggers |
|---|---|
| `authentication` | 401 or 403 on any provider; Gemini 400 whose status is `INVALID_ARGUMENT` and whose message or reason mentions an API key |
| `quota` | 402 on any provider; Fireworks 412; Gemini 429 whose body says the daily quota or billing limit is reached (`quota_exceeded`, "quota" plus "per day", or "billing") |
| `rateLimited(retryAfter)` | other 429s; `Retry-After` (seconds or HTTP-date) or Gemini `RetryInfo.retryDelay` |
| `payloadTooLarge` | 413; a local size check before upload (25 MB for OpenRouter STT; 20 MB for Gemini inline) |
| `timeout` | 408, 504, `URLError.timedOut`, or the explicit request timeout |
| `network` | offline, DNS or connection failures |
| `server` | 5xx (other than 504) and 520–530; OpenRouter 200-with-error |
| `malformedResponse` | 2xx whose body is not parseable or has no text; Gemini prompt blocked or empty candidates |
| `rejected` | other 4xx (bad request, model not found) |

`cancelled` is separate, and the caller should treat it as a user action rather than a provider fault.

User messages contain only the provider name, the category and a retry hint. They never contain the response body, the key, or transcript text. [Certain, as implemented and checked]

## Not verified

- Whether the Fireworks turbo host currently accepts a real key, and its current size limits and pricing.
- Gemini's 413 behaviour, the exact status for an invalid key, and `RetryInfo` presence on generateContent.
- OpenRouter STT and chat with a real key; the ZDR availability of specific models.
- Whether the OpenRouter STT catalogue's `prompt` price is per second.
