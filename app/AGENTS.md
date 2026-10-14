# Preserve the user-tested PR #45 transcription decision

Read [VOCABULARY.md](VOCABULARY.md) before changing transcription providers, dictionary routing, or transcript filtering. The user tested PR #45's implementation and reported that it worked far better, then explicitly asked to preserve it across other PR merges. [Certain]

- Preserve the removal of dictionary-derived prompts from custom OpenAI-compatible transcription and the removal of vocabulary-based output deletion. This implementation removes an echo filter; it does not add one. [Certain]
- Do not restore either behavior incidentally while merging, resolving conflicts, refactoring, or updating providers.
- Keep structured/provider-specific vocabulary support and post-transcription spelling correction. Preserve the existing name/list, prompt-omission, and correction regression checks.
- For an intentional replacement, document the decision and provider-specific evidence for the distinct failure it addresses, preserve useful corrections, and run the checks and build listed in VOCABULARY.md.
