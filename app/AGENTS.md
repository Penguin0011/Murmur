# Preserve the user-tested PR #45 transcription decision

Read [VOCABULARY.md](VOCABULARY.md) before changing transcription providers, dictionary routing, or transcript filtering. The user tested PR #45's implementation and reported that it worked far better, then explicitly asked to preserve it across other PR merges.

- Preserve the removal of dictionary-derived prompts from custom OpenAI-compatible transcription and the removal of vocabulary-based output deletion. This implementation removes an echo filter; it does not add one.
- Do not restore either behavior incidentally while merging, resolving conflicts, refactoring, or updating providers.
- Keep structured/provider-specific vocabulary support and post-transcription spelling correction. Preserve the existing name/list, prompt-omission, and correction regression checks.
- Preserve the Faithful-mode spelling fix: lexicon-gated, unique single-word phonetic respelling with explicit variants first, including the narrowly guarded single-doubled-letter name exception. Keep preferred-only tests without preseeded aliases, the native 425-input false-positive check and the known-name/product safeguards when changing it.
- For an intentional replacement, document the decision and provider-specific evidence for the distinct failure it addresses, preserve useful corrections, and run the checks and build listed in VOCABULARY.md.
