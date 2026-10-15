# Vocabulary routing review — PR #45

Reviewed October 14, 2026, starting at `b19124b`. The original PR expanded an output filter to recognize a trailing “Vocabulary is … Vocabulary is” list. [Certain]

## User-tested decision — preserve when integrating other PRs

After the `ba5f5e2` implementation was built, signature-verified, installed and launched locally on October 14, 2026, the user tested it and reported: “That seems to work far better.” The user explicitly requested that this behavior be preserved when other PRs are merged. [Certain]

**This is the preferred transcription behavior. Preserve PR #45's prompt removal and filter removal when merging overlapping PRs or resolving conflicts. Do not restore the old vocabulary prompt or echo filter as an incidental change.** The improvement the user tested is removal of custom-provider dictionary decoder prompts and vocabulary-based output deletion, not a new output filter. [Certain]

Keep these requirements together:

- Custom OpenAI-compatible transcription must omit dictionary-derived `prompt` text, including for Whisper aliases.
- Cloud transcription must preserve returned names and lists rather than deleting words because they match dictionary entries.
- Keep Gemini's provider-specific vocabulary inputs, local Parakeet vocabulary support, exact manual/learned correction, guarded cleanup correction, and the separate silence/answer safeguards.
- Run `check_providers.swift`, `check_routes.swift`, `check_processing.swift`, `check_dictionary.swift`, and `check_cleanup.swift` using the commands in `app/README.md`, then run `app/build.sh` after integrating overlapping changes.

Any intentional replacement must explicitly address this decision, provide provider-specific evidence for a distinct failure, and retain the spelling-correction and spoken-name regression checks. A broader provider refactor or newer PR alone is not a reason to reverse it.

The user's result is qualitative testing of the installed build, not a controlled benchmark. The provider/model, audio samples, echo counts, and recognition error rates were not recorded in the report. Improvement across all providers is not established. [Certain]

## Faithful spelling regression addressed

The user requested addressing the measured spelling cost. `DictionaryStore.apply` now optionally uses the existing English lexicon and phonetic/semantic learning guard to recover a uniquely matching unfamiliar single word locally, before cleanup. Explicit variants remain authoritative; recognized lowercase/title-case words and names, short words, ambiguity, disabled terms and unlisted phrases stay unchanged. It records no new variant or learning evidence. [Certain]

Reprocessing all 60 stored raw provider outputs with the native lexicon restores the no-prompt Faithful score from 6/18 to **18/18 exact preferred spellings**, matching the prompted control, without any model cleanup. The native 21-term dictionary also leaves all 425 ordinary corpus inputs unchanged beyond explicit variants. Fresh checks and the signed build passed. See [the updated results](../PR45_TEST_RESULTS.md) for evidence and limits. [Certain]

This addresses the failing post-transcription stage; it does not change ASR requests or restore a vocabulary output filter. Unknown real names remain a possible false match, and words recognized by the lexicon or unlisted phrases still require explicit variants or optional model cleanup. Preserve these limits and the corpus checks in future merges. [Certain]

## Original controlled run — acceptance failed before local correction

The fresh [PR #45 test results](../PR45_TEST_RESULTS.md) record 30 paired synthetic-audio comparisons on the actual candidate `fb55557`, using Groq `whisper-large-v3-turbo`, plus six real Standard cleanup calls on Cerebras `gpt-oss-120b`. All 60 ASR calls succeeded without retries, and the deterministic checks, build and signature verification passed. [Certain]

Prompt removal reduced unspoken dictionary additions on direct silence/noise calls from 6/6 to 0/6, but both arms had 0/24 additions during speech. The normal app route skipped the silent fixtures without uploading them, so this does not reproduce the historical long-dictation echo. [Certain]

For the rare-term fixtures, Faithful-mode exact preferred spellings fell from 18/18 with the prompt to 6/18 without it; ignoring capitalization, the comparison was 18/18 versus 9/18. Standard model cleanup recovered the unprompted outputs to 18/18 word spellings ignoring capitalization and 16/18 exact preferred spellings, without guard fallback. [Certain]

The original handoff's no-loss acceptance criterion failed before the local correction fix above. That historical result prompted the follow-up; keep the prompt/filter-removal policy intact. The user's positive local test does not erase this measured tradeoff, and successful Standard cleanup cannot be assumed in Faithful mode or during cleanup failure. [Certain]

## Decision

Remove dictionary `prompt` text from the custom OpenAI-compatible transcription adapter and remove `CloudTranscription.stripHintEcho` entirely. Keep the existing provider-specific Gemini vocabulary inputs, post-transcription dictionary correction, silence pre-check, trailing-silence trimming, and LLM answer detection. [Certain]

The old filter could erase actual speech: `Aakash.`, `Call Aakash, spaceyboi`, or a spoken `Vocabulary: Aakash, spaceyboi.` It ran on every cloud provider, including Gemini's structured-vocabulary ASR, before History saved the raw text. These cases fail against the original PR and pass after removing the filter. [Certain]

Whisper prompt conditioning is the likely cause of the reported labeled echo, rather than an incomplete set of output patterns. This is an inference from the request, the artifact, and decoder semantics; no paired audio replay was performed. [Likely]

## Murmur's flow

`CorrectionLedger.settle` creates a preferred-only learned entry after one consistent session and adds a heard-form variant after two. `DictionaryStore.vocabularyTerms` collects enabled preferred spellings, manual first, deduplicated and with commas removed. The controller passes these to `CloudTranscription.run`, which puts them in `AudioPayload.vocabularyHint`; each provider decides whether to serialize them. Variants are not cloud ASR hints. [Certain]

| Route | Vocabulary input after this change |
|---|---|
| Local Parakeet | `refreshDictionary` writes enabled preferred spellings **and variants as aliases** to private helper JSON. `HelperLaunch` supplies it with the verified optional CTC model; FluidAudio rescoring and `BoostFilter` limit replacements. [Certain] |
| Gemini 3.5 Transcribe | `generation_config.transcription_config.custom_vocabulary`, a structured array of preferred spellings, cleaned and capped at 1,000. [Certain] |
| Gemini audio LLM | Preferred spellings in system instructions, limited to 1,000 characters, explicitly for words actually spoken. JSON transcript parsing and answer detection remain. [Certain] |
| Custom OpenAI-compatible, including Whisper | Audio, model, language, response format and temperature; **no dictionary prompt or invented vocabulary field**. [Certain] |

After transcription, the controller saves raw provider text to History, then `ProcessingCoordinator.prepare` applies explicit dictionary variants and the narrow lexicon-guarded single-word respelling rule in every mode, including Faithful. It collects relevant preferred spellings (exact matches plus at most ten near matches) for optional model cleanup. The cleanup guard permits plausible respellings and rejects unrelated edits; provider failure falls back to local processing of the dictionary-applied text. [Certain]

Thus `Akash → Aakash` and learned `spacey boy → spaceyboi` variants still work without ASR hints, without cleanup, and on cleanup failure. A preferred-only learned `Shelfmate` can still correct `shelf made` through model cleanup. Faithful/local-only processing still does not replace an unlisted multiword phrase such as `shelf made`; unfamiliar single-word forms such as `Shelfmet` can use the guarded local correction. [Certain]

## Why remove rather than reword the Whisper prompt?

[Whisper's decoder](https://github.com/openai/whisper/blob/main/whisper/decoding.py#L535-L557) places prompt tokens after its previous-context marker, before the new transcription. [Groq's Whisper documentation](https://console.groq.com/docs/speech-to-text#prompting-guidelines) describes `prompt` as style/context guidance, not chat instructions. It supports spelling guidance, but lists no structured vocabulary request field. [Certain]

Changing `Vocabulary: Aakash, spaceyboi.` to a bare list removes the label but still supplies decoder context that can be continued or repeated. Adding “do not repeat” instructions uses the same channel. Neither provides a basis for reliably distinguishing a hallucinated name from a spoken name afterward. Removing this optional input eliminates Murmur's dictionary-derived decoder context at the source. It is expected to reduce that echo mechanism, not to eliminate all ASR hallucination. [Likely]

Custom model IDs can be aliases, and Murmur has no capability negotiation for arbitrary servers. The policy therefore applies to the custom adapter, including non-Whisper models, without a `model.contains("whisper")` check. [Certain] A provider with an explicit structured vocabulary contract should get its own adapter if needed. [Likely]

[Gemini's documented `custom_vocabulary`](https://ai.google.dev/gemini-api/docs/transcribe#custom-vocabulary) is a dedicated biasing feature, not prior transcript prose; it supports up to 1,000 terms and cannot be combined with diarization or word timestamps. Murmur already uses that contract, so this change preserves it. Structured biasing does not prove hallucination is impossible. [Certain]

## BetterWispr comparison

Source inspected at [`d504749fc7e86476ef15a522e01d5ed4ef10498c`](https://github.com/opennookorg/betterwispr/tree/d504749fc7e86476ef15a522e01d5ed4ef10498c), the repository's current HEAD when fetched for this review. [Certain]

- [`APISpeechProvider`](https://github.com/opennookorg/betterwispr/blob/d504749fc7e86476ef15a522e01d5ed4ef10498c/Sources/BetterWisprCore/Speech/APISpeechProvider.swift) accepts `vocabulary` but does not use it in requests, including OpenAI-compatible, Sarvam and Smallest routes. [Certain]
- [`WhisperKitProvider`](https://github.com/opennookorg/betterwispr/blob/d504749fc7e86476ef15a522e01d5ed4ef10498c/Sources/BetterWisprCore/Speech/WhisperKitProvider.swift#L96-L109) still feeds a comma-separated list into `promptTokens` (64 terms, 100 characters per term, 160 tokens). This code establishes no echo-prevention guarantee. [Certain] It likely shares the prompt-conditioning risk. [Likely]
- [`AppleSpeechProvider`](https://github.com/opennookorg/betterwispr/blob/d504749fc7e86476ef15a522e01d5ed4ef10498c/Sources/BetterWisprCore/Speech/AppleSpeechProvider.swift) uses `contextualStrings`; [`ParakeetProvider`](https://github.com/opennookorg/betterwispr/blob/d504749fc7e86476ef15a522e01d5ed4ef10498c/Sources/BetterWisprCore/Speech/ParakeetProvider.swift) uses `CustomVocabularyContext` and CTC rescoring. These are distinct vocabulary APIs, not Whisper prompt synonyms. [Certain]
- [`VocabularyProcessor`](https://github.com/opennookorg/betterwispr/blob/d504749fc7e86476ef15a522e01d5ed4ef10498c/Sources/BetterWisprCore/Transcription/VocabularyProcessor.swift) performs exact boundary-aware phrase replacement; [`AppModel`](https://github.com/opennookorg/betterwispr/blob/d504749fc7e86476ef15a522e01d5ed4ef10498c/Sources/BetterWispr/App/AppModel.swift#L420-L455) applies it after optional polishing. These paths establish how it works, not that its accuracy is better. [Certain]

## Evidence and limits

The deterministic checks use synthetic PCM and mocked provider responses, not speech recognition. Before production edits, the new expectations produced five provider assertion failures and 27 route failures against the original PR. [Certain]

- Request tests verify omission of prompts for hosted, LAN and loopback endpoints and Whisper IDs, a private alias, and a non-Whisper ID; audio, model, authentication, and multipart validation remain checked. [Certain]
- Eight transcript cases cross custom, Gemini audio LLM and Gemini ASR routes; all preserve names and lists, including the reported artifact when returned literally. Gemini ASR requests retain their structured vocabulary. [Certain]
- The custom-request-to-processing integration checks raw-text preservation, manual and learned variants without cleanup, a preferred-only learned near match through guarded cleanup, and exact correction on provider failure. Existing dictionary/learning, processing, cleanup and silence checks cover the surrounding flow. [Certain]

The reviewed code and tests establish no distinct failure requiring vocabulary-based text deletion after removing the prompt. Existing audio checks and trimming address the separate silence/noise path. If an unprompted provider still emits the labeled artifact, these tests intentionally preserve it. [Certain] Its audio and provider output would be needed to diagnose the remaining cause. [Likely]

During the initial review, no real provider or representative audio A/B benchmark was run. The tests prove request policy, preservation of literal speech, and downstream correction behavior; they do not quantify echo frequency or rare-term ASR recall. Known variants still correct; near matches require model cleanup. [Certain] Without prompts, unusual words may be recognized less accurately, especially preferred-only learned entries in Faithful mode. [Likely]

Initial review validation on October 14, 2026: 592 provider assertions, 169 route checks, 132 processing checks, and 177 dictionary/learning checks passed. The 425-utterance cleanup suite passed, including 2,349/2,349 adversarial outputs rejected and 2,685/2,685 punctuation transfers preserving words. `git diff --check` and `app/build.sh` passed; the latter built the release helper and optimized app and completed strict code-signature verification. At that stage no app installation, live microphone dictation, or provider replay had been performed; the subsequent installation and user test are recorded above. [Certain]
