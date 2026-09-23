# frozen_string_literal: true

require 'minitest/autorun'
require 'ruby_llm/llm_judge'

class LLMJudgeTest < Minitest::Test
  def fake_engine(digits, provider_options: {})
    queue = Queue.new
    digits.each { |digit| queue << digit }
    scorer = lambda do |_prompt|
      { digit: queue.pop(true), tokens: RubyLLM::Tokens.new(input: 10, output: 1) }
    end
    RubyLLM::LLMJudge::Engine.new(config: RubyLLM.config, provider_options:, scorer:)
  end

  def test_typed_answers_and_token_aggregation
    questions = {
      urgent: { type: :probability, instructions: 'Urgent?', criteria: { yes: 'Today', no: 'Later' } },
      department: { type: :choice, instructions: 'Team?', options: { billing: 'Money', technical: 'Software' } },
      frustration: { type: :score, instructions: 'Mood?', levels: %w[Calm Angry] }
    }
    # Parallel workers can complete in any order. Inspect the option tail of
    # each prompt rather than assigning digits by call order.
    scores = { 'true — Today' => 9, 'false — Later' => 1,
               'billing — Money' => 2, 'technical — Software' => 8,
               '0 — Calm' => 1, '1 — Angry' => 9 }
    scorer = lambda do |prompt|
      digit = scores.fetch(scores.keys.find { |suffix| prompt.end_with?(suffix) })
      { digit:, tokens: RubyLLM::Tokens.new(input: 10, output: 1) }
    end
    engine = RubyLLM::LLMJudge::Engine.new(config: RubyLLM.config, scorer:)
    built = questions.to_h { |name, definition| [name.to_s, RubyLLM::Judge::Question.from_h(name, definition).resolve(nil)] }
    result = engine.judge('Refund today', questions: built, model: RubyLLM::Model.default('gpt-6-luna', 'llm_judge'))

    assert_kind_of RubyLLM::Probability, result.urgent
    assert_operator result.urgent.probability, :>, 0.99
    assert_equal :technical, result.department.choice
    assert_equal %w[Calm Angry], result.frustration.levels
    assert_operator result.frustration.score, :>, 0.99
    assert_equal 60, result.tokens.input
    assert_equal 6, result.tokens.output
    assert_equal 'gpt-6-luna', result.model
  end

  def test_standard_judge_entrypoint
    scores = { 'red — Red' => 9, 'blue — Blue' => 1 }
    scorer = lambda do |prompt|
      { digit: scores.fetch(scores.keys.find { |suffix| prompt.end_with?(suffix) }),
        tokens: RubyLLM::Tokens.new(input: 5, output: 1) }
    end
    engine = RubyLLM::LLMJudge::Engine.new(config: RubyLLM.config, scorer:)
    engine_class = RubyLLM::LLMJudge::Engine
    original_new = engine_class.method(:new)
    engine_class.define_singleton_method(:new) { |**_kwargs| engine }
    begin
      result = RubyLLM::LLMJudge.judge('A red dress', questions: {
        color: { type: :choice, instructions: 'Which color?', options: { red: 'Red', blue: 'Blue' } }
      })
      assert_equal :red, result.color.choice
      assert_equal 'gpt-6-luna', result.model
      assert_equal 2, result.tokens.output
    ensure
      engine_class.define_singleton_method(:new, original_new)
    end
  end

  def test_reusable_judge_subclass_uses_provider_options
    scorer = lambda do |_prompt|
      { digit: 5, tokens: RubyLLM::Tokens.new(input: 3, output: 1) }
    end
    engine_class = RubyLLM::LLMJudge::Engine
    original_new = engine_class.method(:new)
    engine_class.define_singleton_method(:new) do |**options|
      original_new.call(**options, scorer:)
    end
    begin
      judge_class = Class.new(RubyLLM::Judge) do
        model 'gpt-6-luna', provider: :llm_judge, assume_model_exists: true
        provider_options max_arms: 4
        probability :urgent, 'Is this urgent?'
        choice :team, 'Which team?', { billing: 'Payments', other: nil }
      end
      result = judge_class.judge('Please refund today')
      assert_kind_of RubyLLM::Probability, result.urgent
      assert_kind_of RubyLLM::Choice, result.team
      assert_equal 'gpt-6-luna', result.model
      assert_equal 4, result.tokens.output
    ensure
      engine_class.define_singleton_method(:new, original_new)
    end
  end

  def test_tie_reports_zero_confidence
    engine = fake_engine([5, 5])
    question = RubyLLM::Judge::Question.from_h(:choice, type: :choice, options: { a: 'A', b: 'B' }).resolve(nil)
    result = engine.judge('state', questions: { choice: question },
                          model: RubyLLM::Model.default('gpt-6-luna', 'llm_judge'))
    assert_equal :a, result.choice.choice
    assert_equal 0.0, result.choice.confidence
  end

  def test_arm_budget_is_enforced_before_scoring
    engine = fake_engine([], provider_options: { max_arms: 12 })
    options = 7.times.to_h { |index| ["option#{index}", 'option'] }
    first = RubyLLM::Judge::Question.from_h(:first, type: :choice, options:).resolve(nil)
    second = RubyLLM::Judge::Question.from_h(:second, type: :choice, options:).resolve(nil)
    error = assert_raises(ArgumentError) do
      engine.judge('state', questions: { first:, second: },
                   model: RubyLLM::Model.default('gpt-6-luna', 'llm_judge'))
    end
    assert_match(/exceeds 12/, error.message)
  end

  def test_payload_budget_is_enforced_before_scoring
    engine = fake_engine([], provider_options: { max_input_bytes: 32_768 })
    question = RubyLLM::Judge::Question.from_h(:urgent, type: :probability, instructions: 'Urgent?').resolve(nil)
    error = assert_raises(ArgumentError) do
      engine.judge('x' * 32_769, questions: { urgent: question },
                   model: RubyLLM::Model.default('gpt-6-luna', 'llm_judge'))
    end
    assert_match(/input exceeds/, error.message)
  end

  def test_judge_choice_range_including_255_options
    engine = fake_engine(Array.new(255, 5))
    options = 255.times.to_h { |index| ["option#{index}", nil] }
    question = RubyLLM::Judge::Question.from_h(:route, type: :choice, options:).resolve(nil)
    result = engine.judge('state', questions: { route: question },
                          model: RubyLLM::Model.default('gpt-6-luna', 'llm_judge'))

    assert_equal 'option0', result.route.choice
    assert_equal 255, result.route.probabilities.size
    assert_in_delta 1.0 / 255, result.route.probabilities['option254'], 1e-12
    assert_equal 255, result.tokens.output
  end

  def test_single_choice_and_many_questions
    engine = fake_engine(Array.new(15, 5))
    questions = 7.times.to_h do |index|
      name = "question#{index}"
      [name, RubyLLM::Judge::Question.from_h(name, type: :probability).resolve(nil)]
    end
    questions['only'] = RubyLLM::Judge::Question.from_h('only', type: :choice, options: { answer: nil }).resolve(nil)
    result = engine.judge('state', questions:, model: RubyLLM::Model.default('gpt-6-luna', 'llm_judge'))

    assert_equal 8, result.answers.size
    assert_equal :answer, result['only'].choice
    assert_equal 0.0, result['only'].confidence
  end

  def test_full_score_range_and_nil_level
    engine = fake_engine(Array.new(10, 5))
    levels = [nil, *Array.new(9) { |index| "level#{index + 1}" }]
    question = RubyLLM::Judge::Question.from_h(:degree, type: :score, levels:).resolve(nil)
    result = engine.judge('state', questions: { degree: question },
                          model: RubyLLM::Model.default('gpt-6-luna', 'llm_judge'))

    assert_equal levels, result.degree.levels
    assert_equal 10, result.degree.probabilities.size
    assert_in_delta 4.5, result.degree.score, 1e-12
  end

  def test_nil_probability_criteria_remain_undescribed
    engine = fake_engine([])
    question = RubyLLM::Judge::Question.from_h(:urgent, type: :probability,
                                                         criteria: { yes: nil, no: nil }).resolve(nil)
    assert_equal [['true', nil], ['false', nil]], engine.send(:options_for, question)
  end

  def test_scoring_request_matches_digit_protocol
    config = RubyLLM.context { |settings| settings.openai_api_key = 'test-only' }.config
    engine = RubyLLM::LLMJudge::Engine.new(config:)
    chat = engine.send(:scoring_chat)
    chat.add_message(role: :user, content: 'test')
    payload = chat.render

    assert_equal 'gpt-6-luna', payload[:model]
    assert_equal 0, payload[:temperature]
    assert_equal 4, payload[:max_completion_tokens]
    assert_equal 'none', payload[:reasoning_effort]
    assert_equal false, payload[:store]
  end

  def test_non_openai_model_uses_its_own_provider
    config = RubyLLM.context { |settings| settings.anthropic_api_key = 'test-only' }.config
    engine = RubyLLM::LLMJudge::Engine.new(
      config:,
      model: 'claude-haiku-4-5',
      provider_options: { scoring_provider: :anthropic }
    )
    chat = engine.send(:scoring_chat)
    chat.add_message(role: :user, content: 'test')
    payload = chat.render

    assert_match(/\Aclaude-haiku-4-5/, payload[:model])
    assert_equal 4, payload[:max_tokens]
    refute payload.key?(:reasoning_effort)
    refute payload.key?(:store)
  end

  def test_custom_model_is_used_and_reported_by_judge
    scorer = ->(_prompt) { { digit: 5, tokens: RubyLLM::Tokens.new(input: 3, output: 1) } }
    engine_class = RubyLLM::LLMJudge::Engine
    original_new = engine_class.method(:new)
    engine_class.define_singleton_method(:new) { |**options| original_new.call(**options, scorer:) }
    begin
      result = RubyLLM::LLMJudge.judge(
        'Please refund today',
        model: 'claude-haiku-4-5',
        questions: { urgent: { type: :probability, instructions: 'Is this urgent?' } },
        provider_options: { scoring_provider: :anthropic }
      )

      assert_equal 'claude-haiku-4-5', result.model
      assert_equal 'claude-haiku-4-5', result.raw[:scoring_model]
      assert_equal :anthropic, result.raw[:scoring_provider]
    ensure
      engine_class.define_singleton_method(:new, original_new)
    end
  end
end
