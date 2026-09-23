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

## How scoring works

The default `:ratings` strategy asks the model to rate every declared answer from 0 to 9. It makes one call per answer, with up to six calls running at once, then applies softmax to the ratings. The `:single_request` strategy asks for all distributions in one call. Both build the same RubyLLM answer types: a `choice` returns the selected answer and distribution; a `score` returns the distribution and its weighted level; a `probability` returns the positive answer's share. The gem supports Judge's 1–255 choice options, 2–10 score levels, and multiple questions in one judgment.

These probabilities compare the answers you supplied. The `:single_request` values are reported by the chat model; the default ratings values come from softmax over its 0–9 ratings. Neither strategy establishes calibration by itself. Include an `other` or `escalate` choice when the named answers may not cover the input. `confidence` measures how concentrated the returned distribution is. Use labeled examples to set any automation thresholds.

Set optional `max_arms` and `max_input_bytes` in `provider_options` to cap work per judgment. For example, `{ max_arms: 12, max_input_bytes: 32_768 }` rejects larger requests before scoring. Token usage is aggregated across calls, and `raw` contains the ratings and model metadata.

The one-digit-per-answer approach was inspired by [@burkov's post on Jev](https://x.com/burkov/status/2102438687392797045). The one-call strategy follows the typed-question pattern in [TypeSafe's System One adapter](https://github.com/typesafe-ai/system-one-adapter-python).

## Benchmarks

On September 23, 2026, we tested both strategies with **GPT-6 Luna** (OpenRouter) and **DeepSeek V4.1 Flash** (Fireworks), alongside **Jev 1.13.0**. The test used 64 balanced [AG News](https://huggingface.co/datasets/fancyzhx/ag_news) articles with four choices and 32 balanced [SST-2](https://huggingface.co/datasets/stanfordnlp/sst2) sentences. The LLM runs used temperature zero with reasoning disabled. Latency is the median full client round trip, including any corrective retry.

| AG News: 64 decisions | Correct | Brier ↓ | Median / p90 latency |
| --- | ---: | ---: | ---: |
| Luna, one call | 59/64 | 0.1444 | 1,320 / 1,708 ms |
| Luna, parallel ratings | 53/64 | 0.1578 | 1,718 / 2,753 ms |
| Jev, Luna comparison run | 59/64 | **0.1032** | **365 / 586 ms** |
| DeepSeek, one call | 59/64 | 0.1453 | 1,001 / 2,197 ms |
| DeepSeek, parallel ratings | 56/64 | 0.1513 | 2,577 / 3,531 ms |
| Jev, DeepSeek comparison run | 59/64 | **0.1040** | **505 / 1,060 ms** |

| SST-2: 32 judgments | Choice correct | Noul correct | Score correct | Median latency |
| --- | ---: | ---: | ---: | ---: |
| Luna, one call | 29/32 | 29/32 | 29/32 | 1,858 ms |
| Luna, parallel ratings | 28/32 | 30/32 | 28/32 | 3,437 ms |
| Jev, Luna comparison run | 30/32 | 30/32 | 30/32 | 522 ms |
| DeepSeek, one call | 29/32 | 29/32 | 29/32 | 1,443 ms |
| DeepSeek, parallel ratings | 30/32 | 26/32 | 28/32 | 3,009 ms |
| Jev, DeepSeek comparison run | 30/32 | 29/32 | 30/32 | 308 ms |

Each SST-2 judgment asked the same sentiment question as a Choice, a Noul, and a two-level Score. Both final one-call runs returned usable typed answers on **112/112** requests; DeepSeek needed no repair, and Luna needed two corrective retries. On these cases, one call improved AG News accuracy and median latency over parallel ratings for both LLMs. Jev matched or beat their label counts, returned better AG News Brier scores, and was faster. Brier measures the whole probability distribution against the reference label; lower is better.

The Jev and parallel-rating rows come from earlier runs on the same cases, while the one-call rows were measured later. Their latency figures describe these observed runs, not a simultaneous race. These are small public-dataset samples, and the models and providers differ; the numbers are not a model-size-matched comparison. The tested cases also included eight news repeats and eight reversed-choice variants, which are excluded from the 64-case accuracy table.

## Development

The gemspec requires RubyLLM 2.1 because it uses the Judge API. To develop against the unreleased local checkout, set `RUBY_LLM_PATH` to its source path when its declared version reaches 2.1. While that checkout still declares `2.0.0`, load its `lib` directory before this gem's `lib` directory and run `test/llm_judge_test.rb` directly to exercise the Judge code without Bundler's version check.
