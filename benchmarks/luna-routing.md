# Luna provider-routing benchmark

On September 23, 2026, we compared OpenRouter's default route with `provider: { sort: 'latency' }` for GPT-6 Luna through this gem. Both routes used `strategy: :single_request`, temperature zero, reasoning disabled, and `max_output_tokens: 1024`. Each pair judged the same input and questions. We rotated request order across cases and measured the complete Ruby client call with a monotonic clock, including any gem retry. These are application-visible response times, not server inference times.

The 64 AG News cases were split into two consecutive 32-case batches. Each asks for a distribution across four news categories. The 32 SST-2 cases each ask Choice, Probability, and Score sentiment questions in one judgment. They are small, balanced convenience samples from public datasets, not a representative production workload.

| Dataset | Route | Usable | Correct Choice | Median | p90 | Brier ↓ |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| AG News | Default | 64/64 | 61/64 | 1,569 ms | 2,805 ms | 0.0857 |
| AG News | Latency sort | 64/64 | 60/64 | 1,260 ms | 1,812 ms | 0.1165 |
| SST-2 | Default | 32/32 | 29/32 | 2,093 ms | 8,693 ms | 0.0775 |
| SST-2 | Latency sort | 32/32 | 30/32 | 1,507 ms | 1,944 ms | 0.0695 |

For AG News, Brier is the sum of squared probability errors across the four categories, averaged over cases. For SST-2, it is the squared error for the Choice question's positive class, averaged over cases. Lower is better; these are different metrics and should not be compared across datasets.

Latency sort was faster on 50 of 64 matched AG News cases; the median paired difference was −265 ms. It was faster on 21 of 32 SST-2 cases; the median paired difference was −653 ms. Aggregate median latency fell by 19.7% and 28.0%, respectively. The SST-2 default-route p90 includes several long outliers, so its large p90 difference should not be treated as a guaranteed tail-latency reduction.

The speedup may change as OpenRouter's provider pool and routing measurements change. The AG News run lost one correct label and had worse probability error; the SST-2 run gained one label and had slightly lower error. Differences this small do not establish a general quality ranking. `sort: 'latency'` is therefore an opt-in speed preference worth testing on your own labeled cases.

The credential-free results contain case IDs, expected labels, selected choices, reported distributions, usage, and timings: [AG News batch 1](data/luna-routing-agnews-1.json), [AG News batch 2](data/luna-routing-agnews-2.json), and [SST-2](data/luna-routing-sst2.json). Run [the analyzer](analyze_luna_routing.py) to recalculate the table. No input texts or API keys are in these files. The first AG News batch also includes an exploratory Azure-only route; it matched 29/32 labels at 1,328 ms median, so we did not recommend pinning it. We also tried a compact output format in temporary gem code, but its median gain was only about 41 ms across 64 news cases and it lost one more label; that code was discarded.
