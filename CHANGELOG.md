# Changelog

## 0.1.2 (unreleased)

- When a rating call fails, no new calls start and the error is raised once calls in flight finish. Previously the remaining calls kept running, and were billed, after `judge` raised.
- `chat_provider_options` is merged over the defaults instead of replacing them. Setting one option no longer re-enables reasoning or drops `store: false` for Luna.
- One-call JSON inside a Markdown code fence is accepted. Claude Haiku 4.5 now works with `strategy: :single_request`.
- A one-call Choice whose top probabilities tie gets the corrective retry, then raises, instead of selecting the first option. `tie_breaker: :first` keeps the old behavior.
- New `max_workers:` option (default 6) for concurrent rating calls.
- Unknown provider options are named in the error.
- A one-option Choice reports confidence 1.0.
- RubyLLM 1.13 through 1.16: question validation matches RubyLLM 2.1 (duplicate or empty option names, duplicate probability outcomes, description types), and token totals keep cached and thinking tokens.

## 0.1.1 (2026-09-28)

- Fix invalid scoring responses raising `NoMethodError` on RubyLLM 1.13, which also skipped the corrective retry. They now raise `RubyLLM::LLMJudge::Error`, a `RubyLLM::Error`, on every supported RubyLLM version.

## 0.1.0 (2026-09-28)

Initial release.

- `RubyLLM::LLMJudge.judge` answers `probability`, `choice`, and `score` questions with any RubyLLM chat model. The default model is `gpt-6-luna`.
- Registers the `:llm_judge` provider for RubyLLM 2.1's Judge API, so `RubyLLM.judge` and `RubyLLM::Judge` classes return native `Judgment` and typed answers.
- Runs on RubyLLM 1.13 through 1.16, which predate the Judge API. `RubyLLM::LLMJudge.judge` returns `Legacy` answers with the same readers.
- `:ratings` strategy (default): one 0–9 rating per answer, up to six at once, turned into a distribution with softmax. Retries a malformed digit once and breaks tied Choice ratings with a one-call judgment.
- `:single_request` strategy: one call returns a distribution for every question. Validates and normalizes the distributions and makes one corrective retry for malformed JSON.
- `max_arms` and `max_input_bytes` limits reject oversized judgments before any call.
