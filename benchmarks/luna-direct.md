# Direct OpenAI versus OpenRouter Luna

On September 23, 2026, we sent the same one-call Judge prompt for `gpt-6-luna` directly to OpenAI and through OpenRouter with `provider: { sort: 'latency' }`. Both routes used Chat Completions, temperature zero, reasoning disabled, `store: false`, and a 1024-token output limit. Request order alternated across cases. The client measured the full HTTP round trip, including one corrective retry for malformed or incomplete JSON. The direct request used OpenAI's `reasoning_effort: 'none'`; the OpenRouter request used `reasoning: { enabled: false }`.

This API-level benchmark used the gem's one-call system instructions and prompt shape, and extracted the same typed Choice distribution. It was not a 96-case run through the Ruby gem. We also verified four direct calls through the actual gem, including news and sentiment cases; all four produced valid judgments in one attempt.

| Dataset | Route | Usable | Correct Choice | Median | p90 | Brier ↓ | Retried cases |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| AG News (64) | Direct OpenAI | 64/64 | 58/64 | 823 ms | 1,241 ms | 0.1405 | 0 |
| AG News (64) | OpenRouter latency sort | 64/64 | 59/64 | 1,379 ms | 1,938 ms | 0.1265 | 0 |
| SST-2 (32) | Direct OpenAI | 32/32 | 28/32 | 843 ms | 1,745 ms | 0.1042 | 5 |
| SST-2 (32) | OpenRouter latency sort | 32/32 | 29/32 | 1,423 ms | 3,829 ms | 0.0762 | 1 |

Direct OpenAI was faster on 60/64 matched news cases and 27/32 sentiment cases. The median paired differences were −530 ms and −594 ms. Aggregate median latency fell by 40% and 41%, respectively. The direct path lost one correct label on each dataset and had worse probability error, so speed is its demonstrated advantage here. These small balanced public samples do not establish a general quality ranking.

We then repeated **direct OpenAI alone** on the same 96 cases with the same request settings and corrective retry:

| Dataset | Direct run | Usable | Correct Choice | Median | p90 | Brier ↓ | Retried cases |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| AG News (64) | First | 64/64 | 58/64 | 823 ms | 1,241 ms | 0.1405 | 0 |
| AG News (64) | Repeat | 64/64 | 59/64 | 868 ms | 1,198 ms | 0.1205 | 0 |
| SST-2 (32) | First | 32/32 | 28/32 | 843 ms | 1,745 ms | 0.1042 | 5 |
| SST-2 (32) | Repeat | 32/32 | 28/32 | 1,022 ms | 1,682 ms | 0.1090 | 4 |

Only one news choice and two sentiment choices changed between direct runs. News gained one correct label; sentiment had one gain and one loss. Median latency rose by 45 ms on news and 179 ms on sentiment. The repeat supports roughly similar accuracy and median latency around one second, while showing that latency and individual answers vary. OpenRouter was not rerun simultaneously, so its earlier numbers are not a paired latency comparison to this repeat.

AG News Brier is the sum of squared probability errors over four categories, averaged over cases. SST-2 Brier is the squared error for the Choice distribution's positive class, averaged over cases. The metrics have different scales and should not be compared across datasets.

[First-run case results](data/luna-direct-vs-openrouter.json) and [repeat results](data/luna-direct-openai-repeat.json) contain IDs, expected labels, choices, probabilities, usage, timings, and retry counts. No input texts or credentials are saved. Run [the analyzer](analyze_luna_direct.py) to recalculate the tables. The benchmark used the same 64 AG News and 32 SST-2 cases as the other gem comparisons. Provider load and routing can change, so rerun on representative application decisions before selecting a path.
