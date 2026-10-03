# Decision modes: classification versus rule-following

On October 2, 2026, we ran LLM Judge's one-call modes on two kinds of decision, through OpenRouter on RubyLLM 1.13.2, temperature zero. Latency is the median client round trip. [Summary data](data/decision-modes-summary.json).

## Classification: 64 AG News and 32 SST-2 cases

Reasoning disabled. Three passes per row; AG News is the mean (range), SST-2 the mean Choice accuracy. No request failed. Retries are corrective retries per 96 cases, averaged over passes.

| Model | Mode | AG News | Brier ↓ | SST-2 | Retries | Median | Output tokens |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| GPT-5.6 Terra | probabilities | 61.0 (60–62) | 0.106 | 29.0 | 0 | 1,130 ms | 40 |
| GPT-5.6 Terra | probabilities + schema | 60.7 (60–61) | 0.090 | 29.0 | 0 | 1,225 ms | 43 |
| GPT-5.6 Terra | committed | 61.0 (60–62) | — | 29.0 | 0 | 949 ms | 15 |
| GPT-5.6 Luna | probabilities | 60.3 (60–61) | 0.114 | 29.3 | 0 | 1,146 ms | 40 |
| GPT-5.6 Luna | probabilities + schema | 60.3 (59–62) | 0.104 | 30.0 | 0 | 1,184 ms | 44 |
| GPT-5.6 Luna | committed | 58.0 (57–59) | — | 27.3 | 0 | 845 ms | 15 |
| GPT-6 Luna | probabilities | 59.7 (59–60) | 0.113 | 29.0 | 3.3 | 1,007 ms | 39 |
| GPT-6 Luna | probabilities + schema | 59.3 (58–60) | 0.119 | 28.7 | 0.7 | 1,278 ms | 43 |
| GPT-6 Luna | committed + schema | 57.0 (57–57) | — | 29.0 | 0 | 936 ms | 19 |
| Claude Haiku 4.5 | probabilities | 56.0 (56–56) | 0.229 | 29.0 | 0 | 1,065 ms | 81 |
| Claude Haiku 4.5 | probabilities + schema | 56.0 (56–56) | 0.201 | 28.0 | 0 | 1,378 ms | 42 |
| Claude Haiku 4.5 | committed | 56.0 (56–56) | — | 29.0 | 0 | 883 ms | 34 |

Every model and mode combination is in the summary data. Committed answers are one-hot, so their Brier scores are omitted here. On classification, probabilities were as accurate as committed answers or better: 1–3 cases better on the Luna models, tied on Terra and Haiku. Committed answers were 100–300 ms faster with a third of the output. A strict schema had little effect on accuracy; it reduced GPT-6 Luna's corrective retries from 3.3 to 0.7 per 96 cases and added 40–350 ms.

**Prompt order.** A development version listed the questions before the state. Measured on the same cases, it was worse for every model with probabilities: GPT-5.6 Luna 55.7, GPT-6 Luna 56.7, Terra 56.7, and Haiku 55.0 on AG News, with GPT-6 Luna needing 7.7 retries per 96 cases. The released prompt keeps the state first.

## Rule-following: StreamDecisionBench lite v1, untimed

480 states in 8 scenarios. Each state asks six or seven choice questions whose instructions carry a decision policy, and the reference answers come from executable rules ([benchmark](https://github.com/JacobLinCool/StreamDecisionBench)). A state is correct when the composed application decision matches the reference. Our scorer reproduces every published untimed number exactly from the benchmark's recorded runs.

LLM Judge modes, GPT-5.6 Luna, one pass:

| Mode | Reasoning off | Reasoning low |
| --- | ---: | ---: |
| committed + schema | **47.3%** | **90.0%** |
| probabilities | 40.8% | — |
| probabilities + schema | — | **90.0%** |

The benchmark's own method (committed answers with a strict schema, questions before state) published 43.75% off and 88.75% low for this model. With reasoning low, LLM Judge's modes match it; with reasoning off, committed answers did best. Under the development prompt with questions first, probabilities reached only 26.3% off and 84.8% low, and the ratings strategy, which scores each option alone and cannot apply a policy across the state, got 5 of 48 states right on a subset.

Other models, the benchmark's direct method (committed answers, strict schema):

| Model | Reasoning off | Reasoning low | Median (low) | Cost per 480 states (low) |
| --- | ---: | ---: | ---: | ---: |
| GPT-5.6 Terra | 81.5% (3 passes, 80.6–82.7) | 96.5% | 2,442 ms | $4.38 |
| GPT-6 Luna | 52.7% | 92.1% | 2,677 ms | $0.22 |
| GPT-5.6 Luna | 44.4% | 89.4% (3 passes, 88.3–90.6) | 2,712 ms | ~$0.35 |
| Claude Haiku 4.5 | 40.0% | 90.2% | 21,738 ms | $8.07 |
| Jev (decision model) | 61.9% (3 passes, 61.5–62.5) | — | 204 ms | — |
| Clef 27B | 39.0% (3 identical passes) | — | 848 ms | — |
| Kev 4B | 21.9% (3 passes) | — | 1,450 ms | $0.16 |
| Clef Flash | 21.7% | — | 625 ms | — |

## Choosing a mode

- **Classification** (pick a category, rate sentiment): keep reasoning off. Use probabilities (`:single_request`), which were as accurate or better and give calibrated-looking distributions; use committed answers when you only need the label and want the fastest call.
- **Rule-following decisions** (apply a policy to a state): turn reasoning on (effort low). Committed answers with a strict schema and probabilities both reached 90% on GPT-5.6 Luna; GPT-6 Luna reached 92% with the benchmark's method for $0.22 per 480 states. Avoid the ratings strategy for these.
- **Decision models** (Jev, Clef, Kev) answer in 0.2–1.5 s and do well on classification, but reached 22–62% on rule-following states.

Single passes vary: GPT-5.6 Luna low ranged 88.3–90.6% over three passes, so differences of about two points are noise.
