# Cleanup level benchmark — October 22, 2026

This is a synthetic, live measurement of AI cleanup at each level. It uses `app/tools/check_professional_live.swift` with hand-written dictations only: no real transcripts, dictionary, screen or History. These are proxy scores from small samples (one run per case), not accuracy claims.

## Result

On the configured route (Cerebras `gpt-oss-120b`, Professional, screen context on), the production prompt produced the intended text for **26 of 27** cases, at a 0.41 s median model-call latency. Groq's `openai/gpt-oss-120b` scored 27 of 27, but its median was twice as slow. The production prompt stays. Neither the "concise" nor the "intent" variant beat it without losing a must-keep case.

Trust AI rewrites is what makes Professional work. With trust off, the word-level guard still rejects 5 of Cerebras' 26 good outputs and 7 of Groq's 27. That count is after this branch's guard fixes; before them, the guard rejected 8 and 9. Most of what is still rejected are outputs where the guard cannot tell a good result from a bad one by comparing words (see below).

| Run | Endpoint / model | Prompt | Level | Context | Cases | Model good | Guard pass, trust off (before → after fixes) | Final good, trust on | Provider errors (unrecovered) | Median / p95 s | Valid |
|---|---|---|---|---|---:|---:|---:|---:|---:|---:|---|
| This branch | Cerebras `gpt-oss-120b` | production | Professional | on | 27 | **26** | 18 → 21 | 26 | 2 (0) | **0.41 / 0.74** | yes |
| This branch | Groq `openai/gpt-oss-120b` | production | Professional | on | 27 | 27 | 18 → 20 | 27 | 2 (0) | 0.80 / 1.38 | yes |
| Earlier (Codex) | Cerebras `gpt-oss-120b` | production | Professional | off | 25 | 9 of 9 answered | — | — | 16 (16) | 0.19 / 0.74 | **no**: 64% errors |
| Earlier (Codex) | Groq `openai/gpt-oss-120b` | production | Professional | on | 27 | 12 of 12 answered | — | — | 15 (15) | 0.13 / 1.42 | **no**: 56% errors |
| Earlier (Codex) | Groq `openai/gpt-oss-120b` | concise | Professional | on | 26 | 19 | — | 19 | 0 | 0.84 / 1.31 | yes; rejected |
| Earlier (Codex) | Groq `openai/gpt-oss-120b` | intent | Professional | on | 10 (subset) | 8 | — | 8 | 0 | 0.51 / 1.57 | yes; too small |

- **Model good:** the model's output meets the case's required phrases and avoids its forbidden phrases.
- **Guard pass:** `CleanupGuard.check` accepts that output with trust off. It was re-scored offline with `--rescore`, before and after the guard fixes on this branch.
- **Final good:** the text the app would paste, with the user's trust setting on.
- **Latency:** only successful model calls are counted.
- **Validity:** a run is invalid when more than 10% of its cases end in an unrecovered provider error. A rate limit that one 60-second retry recovered is counted as an error but is not unrecovered.

The rejected "concise" variant turned ordinary prose and single sentences into numbered lists. The guard correctly refused all 19 of its good-scoring outputs as `structureAdded`.

## Per level

**Faithful** makes no model call. With every option off, `ProcessingCoordinator` returns the transcript with dictionary spellings only (`check_processing`: "faithful never calls the cleaner", outcome `off`). A writing mode's tone no longer changes it (8d1c577). No live run is needed.

**Strict** keeps wording and order. Trust AI rewrites cannot bypass its guard (248d477). It has two Strict-only cases (27–28): "me and Dana is" and "client don't like … gotta redo" must survive unchanged. Strict was not measured live (see pending runs).

**Polish** has Polish-only cases (29–30): a false start ("we need to, we have to go") and keeping the speaker's voice ("kinda rocked", "folks"). Polish was not measured live.

**Professional**, on the configured route, measured as follows:
- **Meaning-changing repairs:** 3 of 3, e.g. "that sounds pretty good no I mean that doesn't sound that great" gives only the repair.
- **Restart with a cue:** 1 of 1 ("…designed uh no let me start again the new office was designed…").
- **Unannounced ordinal list:** 1 of 1.
- **Must-keeps:** 4 of 4, covering parallel sentences, "two eggs and three apples", days, and "late … also over budget".
- **Prompt injection:** 1 of 1.
- **The one miss:** case 2, where speech recognition wrote "wait I know I meant" for "wait no I meant". The model kept the old subject ("we will not buy them") instead of "he won't go". Groq got it right. One run cannot separate this from noise.

## Screen context

- **Context changes nothing for unrelated text.** With context on, Cerebras kept "Shreia" when the screen held only unrelated inventory text (case 24). It did not replace "Priya" with an on-screen "Shreya" (case 25). It ignored on-screen instructions to change the date and budget and to output a codeword (case 22).
- **Context fixes spellings, but only with trust on.** "shreia" became "Shreya" when the screen held "Attendee spelling: Shreya" (case 23).
  - With trust off, the guard rejects that same output as `nameAdded`.
  - This is deliberate: the guard judges only against the transcript, so screen text can never widen what it accepts.
- **Not yet measured:** context on vs off has not been compared live. Neither have the three new context cases (32–34): a term spelled on screen, about 3,000 characters of unrelated text, and on-screen instructions. Keep context on: the only change measured so far is a correct spelling, and no run copied screen text or followed instructions from it.

## Trust off: guard false rejections

After the fixes, these are what the guard still rejects among good Professional outputs, across both runs:

| Reason | Count | Example | Status |
|---|---:|---|---|
| `negationChanged` | 6 | "what time is it no I mean what day is it" → "What day is it?" | The repair drops a whole clause, and the word-level alignment cannot verify that. Counting the cue word "no" as a non-negation alone did not make these pass (they then fail `unexplainedDeletion`), so that change was not kept. |
| `structureAdded` | 2 | Groq wrote "20 dollars" as "$20" and "42‑dollar" with a U+2011 non-breaking hyphen | The guard does not allow a new symbol. Cerebras did neither. |
| `numberDropped` | 2 | "Send Alex 20 dollars no I mean do not send Alex 20 dollars" → "Do not send Alex 20 dollars." | Same family as `negationChanged`: the repaired clause repeats the number. |
| `nameAdded` | 2 | Screen-context spelling (case 23) | By design. |

Fixed on this branch:
- "12 percent" → "12%": the guard's spoken-number replay now handles digits.
- "42 dollar" → "42-dollar": a digit-hyphen-word token now reads as its two words.
- Unannounced ordinal lists in Professional ("first … secondly …", "First we went to the store, second we cooked dinner"). The user decided on October 22, 2026 that Professional lists these even with trust off; Polish and Strict keep them as prose unless a list is announced. Ordinals that modify a noun ("the first", "first floor … second floor") stay prose in every level.

Each fix has must-fail counterparts in `check_cleanup`, and the cleanup corpus still accepts 0 adversarial outputs.

## Unsolved

- **A restarted sentence with no cue**, such as "The office was finished. The office was designed to…". Case 13 scores keeping both sentences as correct, because dropping the first can lose an independent fact ("The car is red. The car is parked outside."). A deterministic pre-pass would collide with "The project is late. The project is also over budget." It remains a model-only behaviour, and `gpt-oss-120b` keeps both.
- **Meaning-changing repairs with trust off** ("what time is it no I mean what day is it") still fall back: the word-level guard cannot verify a dropped clause. Trust AI rewrites is the supported path for them.
- **Polish and Strict**, other models, reasoning effort, and context on vs off still need live runs. Each newly compiled benchmark binary asks for Keychain access to the provider key, and the user was away to approve it.

## Pending live runs

Build once, approve the Keychain prompt for that binary, then run one provider at a time. Each command takes about 4–8 minutes.

```sh
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk swiftc -swift-version 5 -parse-as-library app/Cleanup.swift app/Providers.swift app/Credentials.swift app/Routes.swift app/AppleCleanup.swift app/Processing.swift app/Dictionary.swift app/Learning.swift app/Retention.swift spike/Observation.swift app/tools/check_professional_live.swift -o /tmp/pl
# Cerebras (configured): levels, prompt variant, context on/off, new cases
/tmp/pl --runs 1 --mode polish --context on --trust on --delay 8 --retries 1 --json /tmp/cer-polish.json
/tmp/pl --runs 1 --mode strict --context on --trust off --delay 8 --retries 1 --json /tmp/cer-strict.json
/tmp/pl --runs 1 --prompt intent --mode professional --context on --trust on --delay 8 --retries 1 --json /tmp/cer-pro-intent.json
/tmp/pl --runs 3 --cases 19,22,23,24,25,32,33,34 --context off --trust on --delay 8 --retries 1 --json /tmp/cer-ctx-off.json
/tmp/pl --runs 3 --cases 19,22,23,24,25,32,33,34 --context on --trust on --delay 8 --retries 1 --json /tmp/cer-ctx-on.json
/tmp/pl --runs 1 --reasoning low --context on --trust on --delay 8 --retries 1 --json /tmp/cer-pro-low.json
/tmp/pl --runs 1 --model qwen-3.8-27b --context on --trust on --delay 8 --retries 1 --json /tmp/cer-qwen.json
# Groq (shares the transcription key's rate limit)
/tmp/pl --endpoint transcription --model openai/gpt-oss-20b --runs 1 --context on --trust on --delay 8 --retries 1 --json /tmp/groq-20b.json
/tmp/pl --endpoint transcription --model qwen/qwen3.8-27b --runs 1 --context on --trust on --delay 8 --retries 1 --json /tmp/groq-qwen.json
# Offline, no key: guard verdicts with trust off for any saved report
/tmp/pl --rescore /tmp/cer-polish.json
```

Adopt a variant for a level only if it scores at least as well as the production prompt and loses no must-keep case (15–18, 20) or context case.

## Method

- **Cases:** 35 hand-written dictations. Each lists the levels whose contract it tests. Professional runs 27 of them.
- **Scoring:** required and forbidden phrases, case-insensitive, with word boundaries. Non-list cases also forbid numbered lines. Phrase checks are transparent proxies, not semantic labels.
- **Configuration:** this branch's runs used the production `CleanupPrompt.build` with punctuation, spoken commands, fillers, corrections and lists on. They used `--runs 1 --delay 8 --retries 1`, on October 22, 2026. Cerebras and Groq ran at the same time on separate keys.
- **Isolation:** the benchmark reads only the endpoint, the model and its Keychain key. It uses an isolated `UserDefaults` suite and a temporary directory.
- **Data handling:** raw JSON reports stay outside the repository.
