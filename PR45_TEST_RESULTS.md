# PR #45 test results

**Status: NOT RUN.** This file is a template for the receiving test agent. No new tests or audio benchmark have been executed as part of writing the handoff. [Certain]

Follow [PR45_TEST_HANDOFF.md](PR45_TEST_HANDOFF.md). Replace placeholders with observed evidence; keep prior results and the user's qualitative improvement report separate from this run.

## Verdict

- Overall: NOT RUN
- Deterministic checks: NOT RUN
- Paired audio: NOT RUN
- Application/correction checks: NOT RUN
- Does the evidence support retaining the current PR #45 policy? NOT ASSESSED
- Main finding and recommendation: PENDING

## Environment and revisions

- Date/time and timezone: PENDING
- Agent / repository path: PENDING
- Candidate commit / PR head / clean or dirty status: PENDING
- Baseline commit: PENDING (plan specifies `b19124b3dbded1d74407ebc1afc529a780f6afa0`)
- macOS / Swift: PENDING
- Tested app path / executable SHA-256, if used: PENDING
- Transcription provider / non-secret host / model / language / request parameters: PENDING
- Cleanup provider/model and options, if used: PENDING
- Dictionary fixture and source badges: PENDING
- Audio source / voice or speaker / preparation method: PENDING
- Absolute evidence-directory path / harness path: PENDING

## Commands and checks

Record each command, exit code, log path and actual assertion count; do not copy historical pass counts as this run's results.

| Check | Status | Exit code / count | Evidence |
|---|---|---|---|
| Providers | NOT RUN | — | — |
| Routes | NOT RUN | — | — |
| Processing | NOT RUN | — | — |
| Dictionary/learning | NOT RUN | — | — |
| Cleanup | NOT RUN | — | — |
| Build and strict signature verification | NOT RUN | — | — |
| Diff check | NOT RUN | — | — |

## Paired audio summary

- Planned/completed pairs and excluded/failed pairs: PENDING
- Same WAV hashes and parameters across each pair verified: NOT RUN
- Original request prompt present / candidate prompt absent verified: NOT RUN
- Raw output captured before filtering/cleanup: NOT RUN
- C09/C10 normal-route skip/upload behavior: NOT RUN

| Metric | A: original prompt | B: no prompt | Interpretation |
|---|---|---|---|
| Unspoken vocabulary additions, C01–C08 | NOT RUN | NOT RUN | — |
| Unspoken vocabulary additions, C01–C02 only | NOT RUN | NOT RUN | — |
| Labeled-list echoes | NOT RUN | NOT RUN | — |
| Direct-provider silence/noise hallucinations, C09–C10 | NOT RUN | NOT RUN | — |
| Raw target spellings correct, C07/C08 | NOT RUN / 18 planned | NOT RUN / 18 planned | — |
| Final target spellings correct, C07/C08 | NOT RUN / 18 planned | NOT RUN / 18 planned | — |
| Optional normalized word error rate | NOT RUN | NOT RUN | — |

Per-call evidence file: PENDING. Include clip ID, repetition, A/B order, exact reference, audio SHA-256/duration, provider/model, request policy, raw text, dictionary-applied text, cleanup/final text if used, guard/fallback result, additions and target-spelling score. Use actual completed denominators.

## Correction and application checks

| Case | Expected | Observed / status / evidence |
|---|---|---|
| Manual + learned exact variants, Faithful | `Call Aakash and spaceyboi.` | NOT RUN |
| Preferred-only learned term, Faithful | `Send a shelf made report.` unchanged | NOT RUN |
| Preferred-only term, model cleanup | Guarded `Shelfmate` correction | NOT RUN |
| Exact variants on mocked cleanup failure | Corrections retained without failed live request | NOT RUN |
| Spoken standalone name, trailing names and literal vocabulary list | No application deletion | NOT RUN |
| Optional normal custom-provider UI recording | Raw/history/final text recorded in disposable field | NOT RUN |

## Counterexamples and failures

PENDING. Include exact synthetic inputs/outputs and audio paths. State whether each issue belongs to raw ASR, application deletion, dictionary correction, cleanup, transport, or the test setup. Write “none observed” only after completing the applicable tests.

## Interpretation and limits

PENDING. Distinguish measured echo reduction from a zero-echo tie, raw spelling from repaired spelling, synthetic from human audio, and this provider/model from untested providers. Document rate limits, missing credentials, incomplete pairs, untested app paths, and any uncertainty. Use [Certain], [Likely], or [Guessing] on factual conclusions; identify guesses explicitly.

## Changes and state left behind

- Production changes made: PENDING (expected: none)
- Temporary harness/fixtures/logs retained at: PENDING
- User settings/dictionary/history modified: PENDING (expected: none)
- App running/path after tests, if touched: PENDING
- Results commit, if created: PENDING
- PR merge status: PENDING (must remain unmerged)

## Summary to return to the originating agent

PENDING: one short paragraph with verdict, measured counts, correction results, material limits, recommendation, and evidence paths. Return this file to the user for relay.
