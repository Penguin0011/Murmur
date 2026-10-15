# PR #45 test handoff

## Assignment and deliverable

Test the current PR #45 behavior, assess whether removing custom-provider dictionary prompts reduces vocabulary echoes while retaining useful spelling corrections, and fill in [PR45_TEST_RESULTS.md](PR45_TEST_RESULTS.md). Do not merge PR #45, change production behavior, restore the removed prompt/filter, or run another agent. Return the completed results file and local evidence paths to the user; the user will bring the results back to the originating agent.

This handoff is a test plan, not a completed test report. The results template starts at NOT RUN. [Certain]

## Context to preserve

- PR: https://github.com/Penguin0011/Murmur/pull/45. Source repository: https://github.com/Penguin0011/Murmur. [Certain]
- Behavior commit: `ba5f5e2` (`fix(transcription): remove dictionary decoder prompts`). Review notes: `d116e50`. User-tested preservation instructions: `263d5ec7c698a3aae041783d58b714a9d85fd94f`. These are the commits present when this handoff was written; verify the actual PR head before testing. [Certain]
- Spelling follow-up: `cc5326e` recovers long unfamiliar single words through the production English lexicon and a unique phonetic/semantic dictionary match, without restoring prompts. The saved-response regression now scores 18/18 in Faithful mode; see the current results for the separate original benchmark and follow-up replay. [Certain]
- Baseline: `b19124b3dbded1d74407ebc1afc529a780f6afa0`, the original PR #45 implementation with the labeled vocabulary prompt and output filter. [Certain]
- The new implementation **removes** dictionary-derived custom transcription prompts and the entire vocabulary echo filter. It does not add a new filter. Gemini's vocabulary inputs, local Parakeet vocabulary support, post-transcription dictionary correction, silence checks/trimming, and LLM answer detection remain. [Certain]
- The built candidate was installed at `/Users/aakash/Applications/Murmur.app` and launched. The user subsequently reported, “That seems to work far better.” This is qualitative user testing; no provider/model or controlled audio measurements accompanied that report. [Certain]
- Read [app/AGENTS.md](app/AGENTS.md) and [app/VOCABULARY.md](app/VOCABULARY.md) before testing. The user explicitly requested preservation of this behavior across overlapping PR merges. [Certain]

## Required follow-up: preferred-only names

The user's live Faithful test exposed `aakash` → `Akash` without an explicit alias. The earlier replay seeded `Akash` and missed this case. Test preferred-only learned `aakash` and `spaceyboi` with **no variants** before testing alias behavior. Require `Please ask Akash to review the report.` → `Please ask aakash to review the report.`; sentence-initial `Akash` becomes `Aakash` under the existing casing policy. Do not alter the user's real dictionary just to run an isolated test. [Certain]

The current rule permits exactly one adjacent doubled letter, with source ≥5 and term ≥6, while preserving lowercase common words, other known-name changes, ambiguity, disabled terms and explicit alias priority. Exercise the persistent preferred-only checks with both fake and native lexicons, and the 28-term native 425-input corpus. Replay the saved 60 provider responses with every dictionary entry preferred-only; record controls separately from the old alias-seeded replay. A fresh live test must omit the workaround alias to count as evidence of automatic correction. Broader known-name substitutions and phrases still need aliases. [Certain]

The user subsequently confirmed the installed revised build produced `Please ask Aakash to review the report.` with Faithful enabled, the Akash heard-as alias removed, and preferred spelling updated to Aakash. Record this as PASS for that user-reported live end-to-end case; repeat the isolated preferred-only tests above for future changes. Raw ASR and final output were not independently captured for the live sentence. See the current results for the evidence limits. [Certain]

## Scope and setup

1. Record repository path, `git rev-parse HEAD`, working-tree status, PR head, macOS/Swift versions, and the executable hash if testing the installed app. Verify that `ba5f5e2` is an ancestor and the request builder omits dictionary prompts. Stop and explain any mismatch before calling a result a candidate result.
2. Use an isolated temporary dictionary, defaults suite, audio directory, and output directory. Do not edit, wipe, reset, or copy private user history/dictionary contents into the report. Keep test fixtures and transcripts local. Record an absolute artifact-directory path in the results.
3. For live calls, use the already configured custom transcription endpoint and model. Record provider name, model ID, and non-secret host only. Respect the destination-bound `.customTranscription` credential through `CustomAPIKeyBinding`/the normal credential store. Do not print keys, dump settings, put credentials in commands, or substitute the cleanup credential. A missing/mismatched credential or unavailable endpoint means live testing is BLOCKED; do not silently switch providers.
4. Send only the synthetic test corpus below or audio explicitly supplied for this test. Use at most 60 ASR calls plus six optional cleanup calls in the initial run. Do not loop through rate limits or provider errors; record incomplete pairs and the safe error classification.
5. Do not quit, replace, or reconfigure the user's running app merely to run an isolated provider benchmark. For a separate live UI smoke test, coordinate a quiet recording window and use a disposable local text field.

The public default endpoint is not proof that the user has a working transcription service configured. `RouteSettings.load`, `makeTranscriptionProvider`, `CustomAPIKeyBinding.read(... provider: .customTranscription)`, and the provider's existing request/transport code are the relevant entry points. [Certain]

## 1. Deterministic checks and build

Run these from the candidate repository root. Preserve exit codes and summaries in local logs; fill in actual results, not the earlier counts. Use unique executable paths if another run is active.

```sh
swiftc app/Cleanup.swift app/Providers.swift app/Credentials.swift app/check_providers.swift -o /tmp/murmur-pr45-providers-check
/tmp/murmur-pr45-providers-check
swiftc app/Cleanup.swift app/Dictionary.swift app/Learning.swift app/Retention.swift app/Providers.swift app/Credentials.swift app/Processing.swift app/Routes.swift app/check_routes.swift -o /tmp/murmur-pr45-routes-check
/tmp/murmur-pr45-routes-check
swiftc app/Cleanup.swift app/Dictionary.swift app/Learning.swift app/Retention.swift app/Providers.swift app/Credentials.swift app/Processing.swift spike/Observation.swift app/check_processing.swift -o /tmp/murmur-pr45-processing-check
/tmp/murmur-pr45-processing-check
swiftc app/Dictionary.swift app/Learning.swift app/Retention.swift app/check_dictionary.swift -o /tmp/murmur-pr45-dictionary-check
/tmp/murmur-pr45-dictionary-check
swiftc app/Cleanup.swift app/check_cleanup.swift -o /tmp/murmur-pr45-cleanup-check
/tmp/murmur-pr45-cleanup-check
app/build.sh
git diff --check
```

Prior review results were 592 provider assertions, 169 route checks, 132 processing checks, 177 dictionary/learning checks, a passing 425-utterance cleanup suite, and a successful optimized build with strict signature verification. These are historical reference values, not this agent's results. [Certain]

Confirm specifically that request tests retain Gemini structured vocabulary and omit custom prompts for Whisper IDs and aliases; route tests preserve spoken names/lists across all three cloud adapters; dictionary integration retains exact manual/learned correction, preferred-only guarded cleanup correction, and exact correction when cleanup fails. [Certain]

## 2. Paired audio comparison — the missing evidence

Use the same prepared WAV bytes, dictionary terms, provider/model, language, temperature, and response format in each pair:

- **A: original request** at `b19124b`, with `prompt="Vocabulary: Aakash, spaceyboi, Shelfmate."`.
- **B: candidate request**, with the prompt field absent.

Use temporary source copies or a small temporary harness that exercises the real request builders and providers; retain the harness with the evidence. Do not alter production code or install the baseline. Verify the two requests differ only in the prompt field (multipart boundary differences are harmless). Do not log the Authorization header or whole requests.

Prepare each audio file once using the current `CloudAudio.prepare`, and reuse those exact bytes for both arms. Keep the existing trailing-silence trim; do not compare different audio preprocessing. Capture the parsed **raw provider text before `CloudTranscription.run` filtering or dictionary/cleanup processing**. The original output filter could hide an echo or delete real speech, so final inserted text alone is an invalid measure of provider echoes. [Certain]

Run ten clips, three paired repetitions each, alternating A/B then B/A order: 30 pairs, at most 60 ASR calls. Save exact reference text, audio-generation method/voice or speaker, duration, SHA-256, pair order, and raw output for every completed call. Synthesized speech is acceptable for a reproducible initial benchmark, but label it synthetic and do not infer general human-speech performance.

| ID | Exact spoken reference / fixture | Purpose |
|---|---|---|
| C01 | “We adjusted the camera settings and sent the report before lunch.” | No dictionary words; detect added hints. |
| C02 | Fixed long ordinary paragraph below, with five seconds of silence appended before normal preprocessing. | Longer dictation without any hint terms. |
| C03 | “Aakash.” | A real standalone name must survive the application path. |
| C04 | “Thanks, Aakash.” | A real name at the end of a sentence. |
| C05 | “Call Aakash, spaceyboi.” | A real list must not be treated as an echo. |
| C06 | “Vocabulary: Aakash, spaceyboi.” | The word “vocabulary” is actually spoken. |
| C07 | “Send the Shelfmate report to Aakash and spaceyboi.” | Useful rare-term spelling. |
| C08 | “Please ask Aakash to call spaceyboi about Shelfmate.” | More spelling contexts; record heard variants. |
| C09 | Two seconds of digital silence; empty reference. | Direct-provider silence hallucinations. |
| C10 | Two seconds of low-level non-speech noise; empty reference. | Direct-provider noise hallucinations. |

For C02, speak/synthesize this exact paragraph and save it as the reference:

> We spent the morning checking the camera settings and reviewing the footage from yesterday. The first recording looked a little dark, so we moved the lamp closer to the desk and opened the curtains. After that, we recorded the same scene again and compared the two versions on the larger screen. The second version showed the details much more clearly. We decided to keep those settings for the next session. Before lunch, I wrote down the steps so someone else could repeat the setup without having to guess. The afternoon plan is to check the microphone, organize the files, and send a short report to the rest of the team. There is no need to change the schedule today. We can review the remaining questions tomorrow after everyone has had time to look at the results. For now, the setup is ready and the report is complete.

C09/C10 direct-provider calls intentionally measure behavior below the app's silence safeguard. Separately verify that the normal candidate route skips those fixtures without an upload when the silence pre-check applies. Do not count a skipped request as an empty ASR response. If your noise fixture exceeds the pre-check threshold, record that instead of changing the threshold. [Certain about the distinction]

## 3. Separate correction and application checks

Use an isolated dictionary with manual `Aakash` / variant `Akash`, learned `spaceyboi` / variant `spacey boy`, and preferred-only learned `Shelfmate`. Do not seed these into the user's real dictionary.

**Supply the production English lexicon when constructing the tested `ProcessingCoordinator`:** use `NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound` on the main actor, as the app does. A processor initialized without `isCommonWord` intentionally stays exact-only and is a control, not the production spelling path. Keep lowercase/title-case recognition, semantic guards, ambiguity and known-name/product regression cases enabled. [Certain]

1. Feed `Call Akash and spacey boy.` through candidate processing in Faithful mode. Require `Call Aakash and spaceyboi.` without any cleanup call. Also preserve the raw input for recovery/history evidence.
2. With Faithful mode, require `Send a shelf made report.` to remain unchanged. Preferred-only entries deliberately do not enable fuzzy local replacement. [Certain]
3. With guarded model cleanup, verify the preferred-only `Shelfmate` correction; record the actual output, guard decision, and whether a fallback occurred. Existing mock-based checks alone do not count as a live cleanup measurement.
4. Repeat exact correction with a mocked cleanup failure. Require manual and learned variants still to apply; this test must make no live failed-provider request.
5. For each arm's recorded audio output, score raw spelling separately from dictionary-applied output. Report any recognition loss on C07/C08 even if post-processing repairs it. Do not describe raw recognition and final spelling as the same metric.
6. If doing UI testing, use normal recording with the configured custom provider and a disposable field. Record route/model, cleanup mode, raw History text and final pasted text using synthetic dictation only. The existing `--test-audio ... --expected-app ...` probe forces local transcription and local processing; it cannot validate this custom-provider change. [Certain]

If only post-transcription dictionary code changed, reuse the saved raw A/B responses to test that stage with the real native lexicon and the same fixture. Record the exact new commit, replayed outputs, control scores and ordinary-corpus checks; label it a replay, not new provider calls. Repeat live ASR only when request/audio behavior changes or evidence leaves a relevant uncertainty.

## 4. Scoring and decision rules

- Count **unspoken vocabulary additions**: dictionary names, hint lists, or “Vocabulary” labels absent from the reference. Do not count C03–C08's actually spoken names/label as echoes. Do not classify an ambiguous result solely from text; retain its audio for review.
- Report speech-only echo counts for C01–C08 (24 runs per arm), no-hint speech counts for C01–C02 (6 per arm), and direct-provider silence/noise hallucinations for C09–C10 (6 per arm), with completed denominators. Report labeled-list echoes separately from isolated additions.
- Report exact target-spelling accuracy on C07/C08 (three intended terms per clip, three repetitions: 18 target occurrences per arm), both raw and after dictionary correction. For optional word error rate, disclose case/punctuation normalization and keep the original outputs.
- Deterministic acceptance: all relevant checks and build pass, no prompt is serialized by the custom adapter, spoken-name/list cases are preserved, and correction checks above pass.
- Audio evidence supports the change if B has fewer unspoken vocabulary additions than A with no loss in final target spelling on this corpus. A tie with zero echoes means **no observed regression; echo reduction not demonstrated**, not proof of causality. Any final spelling loss, added hallucination, deleted spoken content, or check failure requires explicit investigation in the report.
- The user's preferred policy remains the integration baseline. Findings may recommend a follow-up, but the test agent must not reverse the decision or add output filters as part of this assignment.

## 5. Finish and return results

Fill every section of [PR45_TEST_RESULTS.md](PR45_TEST_RESULTS.md). Use PASS, FAIL, BLOCKED, or NOT RUN for each check and an overall PASS / FAIL / INCOMPLETE verdict. Never mark the full validation PASS when live paired audio is missing; separately report deterministic PASS if that is all that ran.

Include exact candidate/baseline commits, commands and exit codes, completed pair counts, raw-output evidence, correction outcomes, counterexamples, limits, and a short recommendation. Keep keys and private dictations out of artifacts and Git. If committing results, include only the Markdown report and synthetic fixtures/harness approved for the repository; link bulky audio/logs through local absolute paths. Do not merge PR #45 or send messages to other chats. The user will relay the report.
