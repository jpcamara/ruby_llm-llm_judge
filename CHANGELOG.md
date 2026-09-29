# Changelog

## 0.1.1 (unreleased)

- Fix invalid scoring responses raising `NoMethodError` on RubyLLM 1.13, which also skipped the corrective retry. They now raise `RubyLLM::LLMJudge::Error`, a `RubyLLM::Error`, on every supported RubyLLM version.

## 0.1.0 (2026-09-28)

Initial release.

- `RubyLLM::LLMJudge.judge` answers `probability`, `choice`, and `score` questions with any RubyLLM chat model. The default model is `gpt-6-luna`.
- Registers the `:llm_judge` provider for RubyLLM 2.1's Judge API, so `RubyLLM.judge` and `RubyLLM::Judge` classes return native `Judgment` and typed answers.
- Runs on RubyLLM 1.13 through 1.16, which predate the Judge API. `RubyLLM::LLMJudge.judge` returns `Legacy` answers with the same readers.
- `:ratings` strategy (default): one 0–9 rating per answer, up to six at once, turned into a distribution with softmax. Retries a malformed digit once and breaks tied Choice ratings with a one-call judgment.
- `:single_request` strategy: one call returns a distribution for every question. Validates and normalizes the distributions and makes one corrective retry for malformed JSON.
- `max_arms` and `max_input_bytes` limits reject oversized judgments before any call.
