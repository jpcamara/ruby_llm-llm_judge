# Claude Haiku 4.5, and the one-call answer shape

On September 29, 2026, we ran Claude Haiku 4.5 (`anthropic/claude-haiku-4.5` through OpenRouter) on the same 64 AG News and 32 SST-2 cases as the other gem comparisons, with RubyLLM 1.13.2, temperature zero, and a 1024-token limit for one-call requests. Latency is the full client round trip, including retries.

| Run | AG News | Brier ↓ | SST-2 Choice / Probability / Score | Median / p90 | Retried |
| --- | ---: | ---: | ---: | ---: | ---: |
| Haiku, one call | 56/64 | 0.2286 | 29 / 29 / 29 | 1,142 / 1,662 ms | 0 |
| Haiku, ratings | 57/64 | 0.1748 | 30 / 28 / 30 | 1,085 / 3,007 ms | 0 (8 tie-breaks) |
| Luna, one call, 0.1.2 instructions | 58/64 | 0.1376 | 29 / 29 / 29 | 936 / 1,158 ms | 2 |
| Luna, one call, 0.1.3 instructions | 60/64 | 0.1129 | 30 / 30 / 30 | 996 / 1,495 ms | 1 |

All 96 judgments were usable in every run. Haiku is a little less accurate than Luna on these cases and its one-call probabilities are less well calibrated; ratings suit it slightly better. Differences of one or two cases on samples this small do not establish a ranking.

**Why the instructions changed.** With the 0.1.2 instructions, Haiku's first one-call answer used the wrong shape on nearly every judgment: first a list of one-question objects, then, once that was accepted, a list of bare distributions with no question IDs. The corrective retry recovered each case, but doubled calls and latency (2.1 s median, 59 of 96 retried). 0.1.3 accepts the list-of-questions shape and adds one sentence to the instructions: the `answers` value must be an object whose keys are the question IDs. Haiku then needed no retries.

Because every model sees these instructions, Luna (OpenRouter, reasoning disabled, latency sort) ran the same cases with both versions back to back. It did at least as well with the new sentence. An intermediate version that showed the shape as a literal JSON template was rejected: Luna began dropping the final closing brace on the three-question SST-2 cases, retrying 8 of 96.

The Haiku ratings run used 0.1.3's list-of-questions parsing but the 0.1.2 instructions, which only its 8 tie-break calls use. The data files contain case IDs, expected labels, answers, usage, and timings, but no input text. Run [the analyzer](analyze_haiku.py) to recalculate the table.
