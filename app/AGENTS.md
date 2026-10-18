# Transcription safeguards

Read [VOCABULARY.md](VOCABULARY.md) before changing transcription providers, dictionary routing or transcript filtering.

- Custom OpenAI-compatible transcription must omit dictionary-derived prompts. Do not delete returned words because they match dictionary entries.
- Preserve provider-specific Gemini vocabulary inputs, local Parakeet support and post-transcription spelling correction.
- Keep explicit variants first, lexicon-gated unique single-word respelling, and the guarded single-doubled-letter name exception. Preserve preferred-only, ordinary-text and known-name regression checks.
- Run the provider, route, processing, dictionary and cleanup checks in [CONTRIBUTING.md](../CONTRIBUTING.md), then build the app when changing these paths.
