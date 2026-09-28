# frozen_string_literal: true

# Runs against RubyLLM releases without the Judge API (1.13 through 1.16).

require 'minitest/autorun'
require 'ruby_llm/llm_judge'

class LegacyTest < Minitest::Test
  QUESTIONS = {
    urgent: { type: :probability, instructions: 'Urgent?', criteria: { yes: 'Today', no: 'Later' } },
    department: { type: :choice, instructions: 'Team?', options: { billing: 'Money', technical: 'Software' } },
    frustration: { type: :score, instructions: 'Mood?', levels: %w[Calm Angry] }
  }.freeze

  SCORES = { 'true — Today' => 9, 'false — Later' => 1,
             'billing — Money' => 2, 'technical — Software' => 8,
             '0 — Calm' => 1, '1 — Angry' => 9 }.freeze

  def setup
    skip 'RubyLLM has the Judge API; see llm_judge_test.rb' if RubyLLM::LLMJudge::NATIVE
  end

  # Builds every engine with the given test doubles, as the entry point constructs its own.
  def with_engine(**doubles)
    engine_class = RubyLLM::LLMJudge::Engine
    original_new = engine_class.method(:new)
    engine_class.define_singleton_method(:new) { |**options| original_new.call(**options, **doubles) }
    yield
  ensure
    engine_class.define_singleton_method(:new, original_new)
  end

  def digit_scorer
    lambda do |prompt|
      { digit: SCORES.fetch(SCORES.keys.find { |suffix| prompt.end_with?(suffix) }),
        tokens: RubyLLM::Tokens.new(input: 10, output: 1) }
    end
  end

  def test_uses_legacy_types
    assert_equal RubyLLM::LLMJudge::Legacy, RubyLLM::LLMJudge::Types
    refute defined?(RubyLLM::LLMJudge::Provider)
  end

  def test_ratings_return_typed_answers
    result = with_engine(scorer: digit_scorer) do
      RubyLLM::LLMJudge.judge('Refund today', questions: QUESTIONS)
    end

    assert_operator result.urgent.probability, :>, 0.99
    assert_equal :probability, result.urgent.type
    assert_equal :technical, result.department.choice
    assert_equal %i[billing technical], result.department.probabilities.keys
    assert_operator result.department.confidence, :>, 0.9
    assert_equal %w[Calm Angry], result.frustration.levels
    assert_operator result.frustration.score, :>, 0.99
    assert_equal 'gpt-6-luna', result.model
    assert_equal 60, result.tokens.input
    assert_equal 6, result.tokens.output
    assert_same result.urgent, result[:urgent]
    assert_same result.urgent, result['urgent']
    assert_same result.urgent, result.fetch('urgent')
    assert_equal %i[urgent department frustration], result.map(&:first)
    assert_equal :technical, result.to_h.dig(:answers, :department, :choice)
    assert_equal 'parallel_0_to_9_softmax', result.raw[:method]
  end

  def test_single_request_returns_typed_answers
    responder = lambda do |_prompt|
      { content: '{"answers":{"department":{"billing":0.2,"technical":0.8}}}',
        tokens: RubyLLM::Tokens.new(input: 30, output: 12) }
    end
    result = with_engine(responder:) do
      RubyLLM::LLMJudge.judge('App crashes on login', questions: QUESTIONS.slice(:department),
                                                      provider_options: { strategy: :single_request })
    end

    assert_equal :technical, result.department.choice
    assert_in_delta 0.8, result.department.probabilities[:technical]
    assert_equal 30, result.tokens.input
    assert_equal 1, result.raw[:attempts]
  end

  def test_string_question_and_option_names_are_preserved
    scorer = ->(prompt) { { digit: prompt.end_with?('calm — null') ? 8 : 1, tokens: RubyLLM::Tokens.new(input: 1, output: 1) } }
    result = with_engine(scorer:) do
      RubyLLM::LLMJudge.judge('Fine', questions: { 'tone' => { type: :choice, options: { 'calm' => nil, 'angry' => nil } } })
    end

    assert_equal 'calm', result['tone'].choice
    assert_equal %w[calm angry], result.tone.probabilities.keys
  end

  def test_invalid_questions_raise
    assert_raises(ArgumentError) { RubyLLM::LLMJudge.judge('x', questions: { a: { type: :vibes } }) }
    assert_raises(ArgumentError) { RubyLLM::LLMJudge.judge('x', questions: { a: { type: :choice, options: {} } }) }
    assert_raises(ArgumentError) { RubyLLM::LLMJudge.judge('x', questions: { a: { type: :score, levels: ['One'] } }) }
    assert_raises(ArgumentError) { RubyLLM::LLMJudge.judge('x', questions: { a: { type: :score, levels: [nil, 'One'] } }) }
    assert_raises(ArgumentError) do
      RubyLLM::LLMJudge.judge('x', questions: { a: { type: :probability, criteria: { maybe: 'Hmm' } } })
    end
    assert_raises(ArgumentError) { RubyLLM::LLMJudge.judge('x', questions: { a: { type: :choice, choices: { b: nil } } }) }
  end

  def test_judge_api_options_raise
    error = assert_raises(ArgumentError) do
      RubyLLM::LLMJudge.judge('x', questions: QUESTIONS, metadata: { id: 1 })
    end
    assert_match(/metadata/, error.message)
  end

  def test_other_protocols_raise
    assert_raises(ArgumentError) do
      RubyLLM::LLMJudge::Engine.new(config: RubyLLM.config, provider_options: { scoring_protocol: :responses })
    end
  end

  def chat_for(provider, model: 'test-model', **options)
    config = RubyLLM.config.dup
    config.openai_api_key = config.anthropic_api_key = config.gemini_api_key = 'test'
    engine = RubyLLM::LLMJudge::Engine.new(config:, model:,
                                           provider_options: { scoring_provider: provider, **options })
    engine.send(:scoring_chat)
  end

  def test_luna_chat_request_settings
    chat = chat_for(:openai, model: 'gpt-6-luna')

    assert_equal({ max_completion_tokens: 4, store: false, reasoning_effort: 'none' }, chat.params)
    assert_equal 0, chat.instance_variable_get(:@temperature)
    assert_equal RubyLLM::LLMJudge::Engine::SYSTEM_INSTRUCTIONS, chat.messages.first.content
  end

  def test_output_limit_uses_each_providers_field
    assert_equal({ max_tokens: 4 }, chat_for(:anthropic).params)
    assert_equal({ generationConfig: { maxOutputTokens: 4 } }, chat_for(:gemini).params)
    assert_equal({ max_tokens: 1024, provider: { sort: 'latency' } },
                 chat_for(:anthropic, max_output_tokens: 1024,
                                      chat_provider_options: { provider: { sort: 'latency' } }).params)
  end
end
