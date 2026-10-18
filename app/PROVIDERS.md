# Provider integration

Configure transcription and cleanup independently in Settings. Cloud routes require your own provider configuration. Review the destination and data disclosure before enabling a route; provider availability, pricing and retention terms must be checked with that provider.

## Configure a route

1. Choose a transcription route in Settings → Transcription and a cleanup route in Settings → Cleanup. Local Parakeet transcription and built-in cleanup need no provider account; Apple Intelligence cleanup depends on system availability.
2. For Gemini, save its API key. The default transcription model ID, `gemini-3.5-transcribe`, uses the Interactions API with `language_codes` set to `en-US` and enabled preferred spellings supplied as structured vocabulary. Other Gemini transcription model IDs use the general audio API.
3. For Custom Provider, enter the service's base URL, model ID and, when required, API key. Transcription and cleanup have separate fields and destination-bound keys. URLs and model IDs apply on Return or focus loss; keys require Save.

| Custom stage | Request | Base URL example |
| --- | --- | --- |
| Transcription | Multipart audio to `/v1/audio/transcriptions`; the server must implement this interface. | `https://api.example.com/v1` |
| Cleanup | Chat-completions JSON to `/v1/chat/completions`. | `http://localhost:11434/v1` |

A base URL can include or omit a trailing `/v1`; do not enter the full request path. Use the server's actual model ID. The local cleanup example requires an already running compatible server with a model loaded; it does not provide local speech recognition. Custom transcription sends no dictionary-derived decoder prompt.

Only loopback destinations count as on this Mac and can work without a key; a local server configured to require authentication still needs its key. LAN and other remote hosts are disclosed as off-Mac. Use HTTPS off-Mac: keys are not sent to unencrypted remote endpoints. Changing an endpoint requires saving its key again for that destination.

Gemini cleanup starts with `gemini-3.5-flash-lite` and can switch to `gemma-4-26b-a4b-it` on quota or rate-limit errors. Long transcripts may be processed in guarded sections while that fallback is active. These are the implementation's model IDs, not a guarantee of current account access. Custom cleanup makes one provider request per dictation. A provider error or rejected rewrite can use guarded local cleanup; a transcription error does not switch to another transcriber.

## Implementation

- `Providers.swift` implements Gemini and custom OpenAI-compatible requests and response validation.
- `Credentials.swift` stores API keys in the macOS Keychain.
- `Routes.swift` resolves configured routes and their disclosures.
- `Processing.swift` applies dictionary correction and cleanup guards. [Vocabulary routing](VOCABULARY.md) explains provider-specific dictionary behavior.

Cloud transcription sends audio. Cloud cleanup sends transcript text, relevant dictionary spellings and any enabled screen context or custom instructions. Cloud meeting notes send transcript content and personal notes. The app treats non-loopback destinations, including LAN hosts, as off-Mac processing.

Do not silently switch transcription providers. Failed or rejected AI cleanup can fall back to local rules. Keep authentication, URL validation, redirect handling, cancellation, response limits and content-free errors intact when changing adapters. Never log keys, audio, transcripts or response bodies.

## Checks

Run the provider, route and processing checks in [CONTRIBUTING.md](../CONTRIBUTING.md), plus `python3 app/check_http.py` for loopback HTTP checks. These checks use synthetic data and do not establish live provider behavior or privacy terms. Use disposable synthetic content for any explicit live test.
