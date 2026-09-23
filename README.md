# ruby_llm-llm_judge

Use a RubyLLM chat model to answer [RubyLLM Judge](https://rubyllm.com/next/judgments/) questions. Define `probability`, `choice`, or `score` questions and receive RubyLLM's native `Judgment` and typed answers. Choose between parallel per-answer ratings and one-call typed distributions.

## Install

```ruby
gem 'ruby_llm', '>= 2.1.0', '< 3.0'
gem 'ruby_llm-llm_judge', path: '/path/to/ruby_llm-llm_judge'
```

Configure your chat provider's credentials through RubyLLM. The default scoring model is `gpt-6-luna`; you can choose another RubyLLM chat model for each judgment.

## Use

```ruby
require 'ruby_llm/llm_judge'

result = RubyLLM::LLMJudge.judge(
  'Please refund the duplicate charge today.',
  questions: {
    urgent: {
      type: :probability,
      instructions: 'Does this need attention today?',
      criteria: { yes: 'An explicit deadline today', no: 'No deadline today' }
    },
    department: {
      type: :choice,
      instructions: 'Which team should handle this?',
      options: { billing: 'Payments and refunds', technical: 'Bugs and integrations' }
    },
    frustration: {
      type: :score,
      instructions: 'How frustrated is the customer?',
      levels: ['Calm', 'Frustrated', 'Angry']
    }
  }
)

result.urgent.probability
result.department.choice
result.department.probabilities
result.frustration.score
result.model  # => "gpt-6-luna"
result.tokens
```

You can also use a reusable Judge class:

```ruby
class TicketTriage < RubyLLM::Judge
  model 'gpt-6-luna', provider: :llm_judge, assume_model_exists: true
  probability :urgent, 'Does this need attention today?'
end

TicketTriage.judge('Please refund today.').urgent.probability
```

## Choose a model

Pass the chat model as `model:` and its provider as `scoring_provider`:

```ruby
result = RubyLLM::LLMJudge.judge(
  'Please refund the duplicate charge today.',
  model: 'claude-haiku-4-5',
  questions: { urgent: { type: :probability, instructions: 'Does this need attention today?' } },
  provider_options: {
    scoring_provider: :anthropic
  }
)
```

The default Luna rating request uses Chat Completions, temperature zero, reasoning disabled, `store: false`, and a four-token output limit. You can tune requests with `scoring_protocol`, `temperature`, `max_output_tokens`, and `chat_provider_options`.

## One-call typed decisions

Set `strategy: :single_request` to send the state and every Judge question to the model in one request:

```ruby
result = RubyLLM::LLMJudge.judge(
  'Please refund the duplicate charge today.',
  questions: {
    urgent: { type: :probability, instructions: 'Does this need attention today?' },
    department: {
      type: :choice,
      instructions: 'Which team should handle this?',
      options: { billing: 'Payments and refunds', technical: 'Bugs and integrations' }
    }
  },
  provider_options: { strategy: :single_request }
)

result.urgent.probability
result.department.probabilities
```

The model returns one JSON object containing a distribution for each question. The gem checks that every question and option is present, validates each probability, normalizes each distribution, and builds RubyLLM's typed answers. `result.raw[:reported_probabilities]` and `result.raw[:reported_totals]` preserve the model's original numbers for inspection. This strategy defaults to an 8192-token output limit to accommodate large Judge requests; set `max_output_tokens` for a smaller known workload. It makes one corrective retry for malformed JSON or missing fields, counting both calls in `result.tokens` and `result.raw[:attempts]`. Set `malformed_retries: 0` to disable that retry. An invalid response after retries raises an error.

For faster Luna judgments through OpenRouter, prioritize the provider with the lowest observed latency:

```ruby
result = RubyLLM::LLMJudge.judge(
  'Please refund the duplicate charge today.',
  model: 'openai/gpt-6-luna',
  questions: {
    department: {
      type: :choice,
      instructions: 'Which team should handle this?',
      options: { billing: 'Payments and refunds', technical: 'Bugs and integrations' }
    }
  },
  provider_options: {
    strategy: :single_request,
    scoring_provider: :openrouter,
    temperature: 0,
    max_output_tokens: 1024,
    chat_provider_options: {
      reasoning: { enabled: false },
      provider: { sort: 'latency' }
    }
  }
)
```

This example uses a 1024-token output limit for a small judgment. Omit that option for large question sets. OpenRouter's [latency sorting](https://openrouter.ai/docs/guides/routing/provider-selection) chooses among its available providers using their observed response times. The measured speed and answer-quality tradeoff is below.

## How scoring works

The default `:ratings` strategy asks the model to rate every declared answer from 0 to 9. It makes one call per answer, with up to six calls running at once, then applies softmax to the ratings. It retries a malformed digit once. When the highest ratings tie on a Choice question, it makes a one-call JSON judgment for that question and uses its distribution. If that call also ties, it raises an error instead of choosing whichever option came first. `result.raw[:tie_breaks]` records each resolution, and token usage includes the extra call. Set `tie_breaker: :first` to use the original first-option rule, or `tie_break_max_output_tokens:` to change the tie-break response limit (default 8192).

The `:single_request` strategy asks for all distributions in one call. Both strategies build the same RubyLLM answer types: a `choice` returns the selected answer and distribution; a `score` returns the distribution and its weighted level; a `probability` returns the positive answer's share. The gem supports Judge's 1–255 choice options, 2–10 score levels, and multiple questions in one judgment.

These probabilities compare the answers you supplied. The `:single_request` values are reported by the chat model; the default ratings values come from softmax over its 0–9 ratings. Neither strategy establishes calibration by itself. Include an `other` or `escalate` choice when the named answers may not cover the input. `confidence` measures how concentrated the returned distribution is. Use labeled examples to set any automation thresholds.

Set optional `max_arms` and `max_input_bytes` in `provider_options` to cap work per judgment. For example, `{ max_arms: 12, max_input_bytes: 32_768 }` rejects larger requests before scoring. Token usage is aggregated across calls, and `raw` contains the ratings and model metadata.

The one-digit-per-answer approach was inspired by [@burkov's post on Jev](https://x.com/burkov/status/2102438687392797045). The one-call strategy follows the typed-question pattern in [TypeSafe's System One adapter](https://github.com/typesafe-ai/system-one-adapter-python).

## Benchmarks

On September 23, 2026, we tested GPT-6 Luna (OpenRouter), DeepSeek V4.1 Flash (Fireworks), [Celeris-1](https://docs.celeris.ai/making-requests), and Jev 1.13.0 on 64 balanced [AG News](https://huggingface.co/datasets/fancyzhx/ag_news) articles with four choices and 32 balanced [SST-2](https://huggingface.co/datasets/stanfordnlp/sst2) sentences. LLM runs used temperature zero with reasoning disabled. **Correct** counts all cases; **Usable** counts cases that returned a valid judgment. Brier scores and latency use usable cases only. Latency is the full client round trip, including retries.

| AG News model | Method | Correct / 64 | Usable / 64 | Brier ↓ | Median / p90 latency |
| --- | --- | ---: | ---: | ---: | ---: |
| Luna | One call | 59 | 64 | 0.1444 | 1,320 / 1,708 ms |
| Luna | Parallel ratings | 53 | 64 | 0.1578 | 1,718 / 2,753 ms |
| DeepSeek | One call | 59 | 64 | 0.1453 | 1,001 / 2,197 ms |
| DeepSeek | Parallel ratings | 56 | 64 | 0.1513 | 2,577 / 3,531 ms |
| Celeris | Plain one call | 54 | 58 | 0.1284 | 428 / 744 ms |
| Celeris | Original ratings | 42 | 54 | 0.1998 | 505 / 861 ms |
| Celeris | Original ratings, rerun | 47 | 58 | 0.1754 | 537 / 889 ms |
| Celeris | Ratings + retry/tie-break, run 1 | 57 | 61 | 0.1284 | 545 / 1,137 ms |
| Celeris | Ratings + retry/tie-break, run 2 | 56 | 59 | 0.1153 | 545 / 1,009 ms |
| Celeris | JSON one call + retry, run 1 | 60 | 63 | 0.0958 | 453 / 852 ms |
| Celeris | JSON one call + retry, run 2 | 59 | 62 | 0.1107 | 401 / 776 ms |
| Jev | Luna paired run | 59 | 64 | 0.1032 | 365 / 586 ms |
| Jev | DeepSeek paired run | 59 | 64 | 0.1040 | 505 / 1,060 ms |

| SST-2 model | Method | Choice / 32 | Probability / 32 | Score / 32 | Usable / 32 | Median latency |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Luna | One call | 29 | 29 | 29 | 32 | 1,858 ms |
| Luna | Parallel ratings | 28 | 30 | 28 | 32 | 3,437 ms |
| DeepSeek | One call | 29 | 29 | 29 | 32 | 1,443 ms |
| DeepSeek | Parallel ratings | 30 | 26 | 28 | 32 | 3,009 ms |
| Celeris | Plain one call | 29 | 29 | 29 | 32 | 282 ms |
| Celeris | Original ratings | 28 | 24 | 26 | 30 | 530 ms |
| Celeris | Ratings + retry/tie-break, run 1 | 28 | 24 | 28 | 32 | 577 ms |
| Celeris | JSON one call + retry, run 1 | 28 | 28 | 28 | 32 | 248 ms |
| Celeris | JSON one call + retry, run 2 | 28 | 28 | 28 | 32 | 264 ms |
| Jev | Luna paired run | 30 | 30 | 30 | 32 | 522 ms |
| Jev | DeepSeek paired run | 30 | 29 | 30 | 32 | 308 ms |

The original 42/64 Celeris ratings result was not a one-off: the same behavior scored 47/64 in a fresh control run. In the original run, 10 cases returned no usable judgment and nine of the 12 incorrect usable choices had tied top ratings. With malformed-digit retry and Choice tie resolution, two runs scored 57/64 and 56/64. Those runs resolved nine of ten and seven of seven top ties to the reference label. Their observed median and p90 latencies were higher; tie-break calls add work. The control and revised run 2 covered only the 64 news cases; revised run 1 covered all 112 requests. Jev rows are saved earlier paired runs on the same cases, while Celeris was measured later.

### Faster Luna routing

A fresh paired run sent the same one-call Luna judgments through OpenRouter's default route and `provider: { sort: 'latency' }`, rotating request order across cases. All responses were usable. Each AG News request asked one four-choice question; each SST-2 request asked Choice, Probability, and Score together. Both routes used temperature zero, reasoning disabled, and a 1024-token output limit. These results are separate from the runs above.

| Dataset | OpenRouter route | Correct | Median | p90 | Brier ↓ |
| --- | --- | ---: | ---: | ---: | ---: |
| AG News (64) | Default | 61/64 | 1,569 ms | 2,805 ms | 0.0857 |
| AG News (64) | Lowest latency | 60/64 | 1,260 ms | 1,812 ms | 0.1165 |
| SST-2 (32) | Default | 29/32 | 2,093 ms | 8,693 ms | 0.0775 |
| SST-2 (32) | Lowest latency | 30/32 | 1,507 ms | 1,944 ms | 0.0695 |

Latency sorting reduced median time by 20% on AG News and 28% on SST-2. It was faster on 50/64 and 21/32 matched cases, respectively. AG News lost one correct label and its Brier score worsened; SST-2 gained one correct label. Check this route on your own labeled decisions before relying on its probabilities. [Methods and case-level data](benchmarks/luna-routing.md).

## Development

The gemspec requires RubyLLM 2.1 because it uses the Judge API. To develop against the unreleased local checkout, set `RUBY_LLM_PATH` to its source path when its declared version reaches 2.1. While that checkout still declares `2.0.0`, load its `lib` directory before this gem's `lib` directory and run `test/llm_judge_test.rb` directly to exercise the Judge code without Bundler's version check.
