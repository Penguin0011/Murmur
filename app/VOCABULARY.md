# Vocabulary routing

Dictionary entries support preferred spellings and explicit misheard variants. Preserve spoken names and lists; a dictionary match alone is never a reason to delete provider output.

## Transcription routes

| Route | Vocabulary input |
|---|---|
| Local Parakeet | Enabled preferred spellings and variants, supplied to the verified optional CTC model; `BoostFilter` limits replacements. |
| Gemini Transcribe | Structured `custom_vocabulary` containing preferred spellings, capped at 1,000. |
| Gemini audio LLM | Preferred spellings in instructions, limited to 1,000 characters and words actually spoken. |
| Custom OpenAI-compatible | No dictionary-derived prompt or invented vocabulary field, including for Whisper models. |

Whisper prompts can be continued as prior speech, producing unspoken dictionary text. Removing such text afterward can also erase deliberately spoken names or lists. Keep prompt omission and literal-output preservation together. Silence checks, trailing-silence trimming and answer detection are separate safeguards.

## Post-transcription correction

Raw provider text is saved before processing. Explicit dictionary variants apply first in every mode, including Faithful. With the English lexicon, unfamiliar single words can use a unique enabled spelling with matching phonetic and semantic guards. A narrow exception permits one adjacent doubled-letter expansion for a recognized title-case name when its lowercase form is unrecognized. Already-correct preferred spellings take priority.

Recognized ordinary words, ambiguous matches, disabled entries and unlisted phrases remain protected. Optional model cleanup can use relevant preferred spellings; its guard rejects unrelated edits, and a provider failure falls back to local processing.

Without ASR prompts, unusual spellings can be recognized less accurately. The local name exception can replace an intended alternate name with a stored spelling. Explicit variants remain necessary for other short or ambiguous forms and unlisted phrases; synthetic checks do not establish real-speech accuracy.

## Checks

Use [CONTRIBUTING.md](../CONTRIBUTING.md) for compilation commands. Keep request-prompt omission and spoken-name/list cases in `check_providers.swift` and `check_routes.swift`, correction and fallback cases in `check_processing.swift` and `check_dictionary.swift`, and ordinary-text/adversarial cases in `check_cleanup.swift`. Run `app/build.sh` after integrating changes.
