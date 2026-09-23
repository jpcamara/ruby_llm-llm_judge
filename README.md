# ruby_llm-llm_judge

Use a RubyLLM chat model to answer [RubyLLM Judge](https://rubyllm.com/next/judgments/) questions. Define `probability`, `choice`, or `score` questions and receive RubyLLM's native `Judgment` and typed answers. The gem scores the declared answers concurrently.

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

The default Luna request uses Chat Completions, temperature zero, reasoning disabled, `store: false`, and a four-token output limit. You can tune requests with `scoring_protocol`, `temperature`, `max_output_tokens`, and `chat_provider_options`. The scoring model must return one ASCII digit from 0 to 9 for each answer; an invalid response raises an error.

## How scoring works

For each question, the gem asks the model to rate every declared answer from 0 to 9. It makes one call per answer, with up to six calls running at once, then applies softmax to the ratings. A `choice` returns the highest-rated answer and the distribution; a `score` returns the distribution and its weighted level; a `probability` returns the positive answer's share. The gem supports Judge's 1–255 choice options, 2–10 score levels, and multiple questions in one judgment.

These probabilities compare the answers you supplied; they are not calibrated estimates of real-world correctness. Include an `other` or `escalate` choice when the named answers may not cover the input. `confidence` measures how concentrated the returned distribution is. Use labeled examples to set any automation thresholds.

Set optional `max_arms` and `max_input_bytes` in `provider_options` to cap work per judgment. For example, `{ max_arms: 12, max_input_bytes: 32_768 }` rejects larger requests before scoring. Token usage is aggregated across calls, and `raw` contains the ratings and model metadata.

The one-digit-per-answer approach was inspired by [@burkov's post on Jev](https://x.com/burkov/status/2102438687392797045).

## Development

The gemspec requires RubyLLM 2.1 because it uses the Judge API. To develop against the unreleased local checkout, set `RUBY_LLM_PATH` to its source path when its declared version reaches 2.1. While that checkout still declares `2.0.0`, load its `lib` directory before this gem's `lib` directory and run `test/llm_judge_test.rb` directly to exercise the Judge code without Bundler's version check.
