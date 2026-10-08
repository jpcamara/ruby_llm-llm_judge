# Claude Haiku 5.5

On October 8, 2026, we ran Claude Haiku 5.5 (`anthropic/claude-haiku-5.5` through OpenRouter) on the gem's
classification cases and on StreamDecisionBench. On the same day, through the same route, we re-ran Claude
Haiku 4.5 on the classification cases. Runs used RubyLLM 1.13.2 and this branch of LLM Judge. Latency is the
full client round trip, including retries. Cost uses OpenRouter's list prices: $0.10 / $0.50 per million input
/ output tokens for Haiku 5.5, and $1 / $5 for Haiku 4.5. [Summary data](data/haiku-5-5.json); recompute it
with [the analyzer](analyze_haiku_5_5.py).

## Why it needs a default

Haiku 5.5 thinks by default. The ratings strategy asks for one digit with a four-token output limit, and Haiku
5.5 spent all four tokens on reasoning and returned nothing (`finish_reason: length`, 4 reasoning tokens, empty
content). With `reasoning: { enabled: false }`, it returned the digit in 3 tokens. LLM Judge now sends that for
Haiku 5.5's OpenRouter IDs, as it does for Luna. OpenRouter doesn't list `temperature` as a supported parameter
for Haiku 5.5, so the gem leaves it unset.

## Classification: 64 AG News and 32 SST-2 cases

Reasoning off, three passes per row. AG News is the mean (range), SST-2 the mean Choice accuracy. No request
failed.

| Model | Mode | AG News | Brier ↓ | SST-2 | Retries / 96 | p50 | p95 | $ / 1k |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Haiku 5.5 | probabilities + schema | **59.7 (59–60)** | **0.132** | 30.0 | 0 | 1,520 ms | 1,750 ms | $0.11 |
| Haiku 5.5 | probabilities | 56.7 (56–57) | 0.165 | 30.0 | 1.3 | 1,244 ms | 1,595 ms | $0.07 |
| Haiku 5.5 | ratings | 57.7 (57–58) | 0.134 | 30.0 | 0 | 1,305 ms | 2,603 ms | $0.10 |
| Haiku 5.5 | committed | 55.0 (54–56) | — | 30.0 | 0 | 1,178 ms | 1,443 ms | **$0.05** |
| Haiku 5.5 | committed + schema | 55.7 (55–56) | — | 30.0 | 0 | 1,152 ms | 1,405 ms | $0.08 |
| Haiku 4.5 | probabilities + schema | 56.0 (56–56) | 0.201 | 28.0 | 0 | 1,490 ms | 1,977 ms | $0.85 |
| Haiku 4.5 | probabilities | 56.0 (56–56) | 0.229 | 29.0 | 0 | 1,141 ms | 2,506 ms | $0.69 |
| Haiku 4.5 | ratings | 58.0 (58–58) | 0.180 | 30.0 | 0 | 1,121 ms | 3,396 ms | $0.80 |
| Haiku 4.5 | committed | 56.0 (56–56) | — | 29.0 | 0 | 946 ms | 1,658 ms | $0.42 |

With reasoning low (one pass), Haiku 5.5 reached 60/64 with probabilities (Brier 0.135, p50 1,314 ms) and 59/64
with committed answers and a schema. On classification that is within a case of reasoning off.

Recorded results for comparison: GPT-5.6 Terra with probabilities scored 61.0 and 29.0
([decision modes](decision-modes.md)); GPT-6 Luna 59.7 and 29.0; Jev 59 and 30. Differences of one or two
cases on samples this small don't establish a ranking.

## Rule-following: StreamDecisionBench lite v1, untimed

480 states, each with six or seven choice questions carrying a decision policy. The method is described in
[decision modes](decision-modes.md#rule-following-streamdecisionbench-lite-v1-untimed).

| Model | Method | Reasoning off | Reasoning low | p50 / p95 (low) | $ / 1k states (low) |
| --- | --- | ---: | ---: | ---: | ---: |
| Haiku 5.5 | LLM Judge, committed + schema | 12.7% | **96.3%** | 5,985 / 10,480 ms | $1.12 |
| Haiku 5.5 | Benchmark's direct method | 24.4% (2 passes, 23.8–25.0) | 95.8% | 5,919 / 10,456 ms | $0.82 |
| Haiku 4.5 | Benchmark's direct method (recorded) | 40.0% | 90.2% | 21,738 ms (p50) | $16.81 |
| GPT-5.6 Terra | Benchmark's direct method (recorded) | 81.5% | 96.5% | 2,442 ms (p50) | $9.13 |
| GPT-6 Luna | Benchmark's direct method (recorded) | 52.7% | 92.1% | 2,677 ms (p50) | $0.46 |
| Jev | Decision model (recorded) | 61.9% | — | 204 ms | — |

With reasoning low, Haiku 5.5 matched GPT-5.6 Terra's accuracy, at about a twentieth of Haiku 4.5's cost and a
quarter of its latency. With reasoning off, it did worse than every model here except the small decision
models: it needs reasoning to apply a policy. Its answers with reasoning off weren't degenerate. They spread
across options the way the reasoning-low answers do; they were just wrong more often.

## Recommended settings

- **Classification:** `strategy: :single_request, structured_output: true`, reasoning off (the default). It was
  the most accurate and best calibrated configuration, at about $0.11 per 1,000 judgments.
- **Fastest and cheapest label:** `strategy: :committed`, reasoning off: 1.2 s, $0.05 per 1,000.
- **Rule-following questions:** `strategy: :committed, structured_output: true` with reasoning low, in
  OpenRouter's format: `chat_provider_options: { reasoning: { enabled: nil, effort: 'low' } }` and
  `max_output_tokens: 8192`. Expect 6–10 s per judgment.
- **The ratings strategy** works with the default (reasoning off). Don't turn reasoning on with it.

Runs: 96 classification cases × 5 modes × 3 passes for each Haiku model, plus 2 reasoning-low passes, and
480 states × 5 runs. All of it cost about $2.60 through OpenRouter.
