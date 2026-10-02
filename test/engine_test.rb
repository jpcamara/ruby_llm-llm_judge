# frozen_string_literal: true

# Runs on every supported RubyLLM through RubyLLM::LLMJudge.judge, so it
# covers both the Judge API path and the pre-2.1 Legacy path.

require 'minitest/autorun'
require 'json'
require 'ruby_llm/llm_judge'

class EngineTest < Minitest::Test
  TEAM = { team: { type: :choice, instructions: 'Team?', options: { billing: 'Money', technical: 'Software' } } }.freeze

  def tokens(input = 10, output = 1) = RubyLLM::Tokens.new(input:, output:)

  # Builds every engine with the given test doubles, as the entry point constructs its own.
  def with_engine(**doubles)
    engine_class = RubyLLM::LLMJudge::Engine
    original_new = engine_class.method(:new)
    engine_class.define_singleton_method(:new) { |**options| original_new.call(**options, **doubles) }
    yield
  ensure
    engine_class.define_singleton_method(:new, original_new)
  end

  def options(count) = count.times.to_h { |index| [:"option#{index}", "Option #{index}"] }

  def test_a_failed_rating_stops_new_calls
    calls = 0
    scorer = lambda do |_prompt|
      calls += 1
      raise RubyLLM::LLMJudge::Error, 'no digit'
    end

    error = assert_raises(RubyLLM::LLMJudge::Error) do
      with_engine(scorer:) do
        RubyLLM::LLMJudge.judge('x', questions: { pick: { type: :choice, options: options(5) } },
                                     provider_options: { max_workers: 1 })
      end
    end
    assert_equal 'no digit', error.message
    assert_equal 1, calls
  end

  def test_no_rating_calls_continue_after_judge_raises
    calls = Queue.new
    scorer = lambda do |prompt|
      calls << prompt
      raise RubyLLM::LLMJudge::Error, 'no digit' if prompt.end_with?('option0 — Option 0')

      sleep 0.02
      { digit: 5, tokens: tokens }
    end

    assert_raises(RubyLLM::LLMJudge::Error) do
      with_engine(scorer:) do
        RubyLLM::LLMJudge.judge('x', questions: { pick: { type: :choice, options: options(24) } },
                                     provider_options: { max_workers: 3 })
      end
    end
    finished = calls.size
    sleep 0.1
    assert_equal finished, calls.size, 'rating calls ran after judge raised'
    assert_operator finished, :<, 24
  end

  def test_max_workers_caps_concurrent_calls
    lock = Mutex.new
    active = 0
    peak = 0
    scorer = lambda do |_prompt|
      lock.synchronize { peak = [peak, active += 1].max }
      sleep 0.02
      lock.synchronize { active -= 1 }
      { digit: 5, tokens: tokens }
    end

    with_engine(scorer:) do
      RubyLLM::LLMJudge.judge('x', questions: { pick: { type: :choice, options: options(12) } },
                                   provider_options: { max_workers: 3, tie_breaker: :first })
    end
    assert_equal 3, peak
  end

  def test_provider_option_errors_name_the_problem
    error = assert_raises(ArgumentError) do
      RubyLLM::LLMJudge.judge('x', questions: TEAM, provider_options: { stratgey: :single_request })
    end
    assert_match(/Unknown LLMJudge provider options: stratgey/, error.message)

    %i[max_workers].each do |key|
      [0, -1, 1.5, '2'].each do |value|
        assert_raises(ArgumentError) { RubyLLM::LLMJudge.judge('x', questions: TEAM, provider_options: { key => value }) }
      end
    end
  end

  def test_single_request_accepts_json_in_a_code_fence
    ["```json\n{\"answers\":{\"team\":{\"billing\":0.2,\"technical\":0.8}}}\n```",
     "  ```\n{\"answers\":{\"team\":{\"billing\":0.2,\"technical\":0.8}}}\n```  ",
     "```JSON {\"answers\":{\"team\":{\"billing\":0.2,\"technical\":0.8}}}```"].each do |content|
      responder = ->(_prompt) { { content:, tokens: tokens } }
      result = with_engine(responder:) do
        RubyLLM::LLMJudge.judge('x', questions: TEAM, provider_options: { strategy: :single_request })
      end

      assert_equal :technical, result.team.choice, content
      assert_equal 1, result.raw[:attempts]
    end
  end

  def test_single_request_accepts_answers_as_a_list_of_questions
    content = '{"answers":[{"team":{"billing":0.2,"technical":0.8}},{"urgent":{"true":0.9,"false":0.1}}]}'
    responder = ->(_prompt) { { content:, tokens: tokens } }
    result = with_engine(responder:) do
      RubyLLM::LLMJudge.judge('x', questions: TEAM.merge(urgent: { type: :probability }),
                                   provider_options: { strategy: :single_request })
    end

    assert_equal :technical, result.team.choice
    assert_in_delta 0.9, result.urgent.probability
    assert_equal 1, result.raw[:attempts]
  end

  def test_single_request_rejects_a_list_that_repeats_a_question
    content = '{"answers":[{"team":{"billing":0.2,"technical":0.8}},{"team":{"billing":0.9,"technical":0.1}}]}'
    responder = ->(_prompt) { { content:, tokens: tokens } }
    error = assert_raises(RubyLLM::LLMJudge::Error) do
      with_engine(responder:) do
        RubyLLM::LLMJudge.judge('x', questions: TEAM, provider_options: { strategy: :single_request, malformed_retries: 0 })
      end
    end
    assert_match(/Question IDs must be/, error.message)
  end

  def test_committed_answers_are_one_hot
    content = '{"answers":{"team":"technical","urgent":true,"mood":1}}'
    responder = ->(_prompt) { { content:, tokens: tokens } }
    result = with_engine(responder:) do
      RubyLLM::LLMJudge.judge('x', questions: TEAM.merge(urgent: { type: :probability },
                                                         mood: { type: :score, levels: %w[Calm Angry] }),
                                   provider_options: { strategy: :committed })
    end

    assert_equal :technical, result.team.choice
    assert_equal({ billing: 0.0, technical: 1.0 }, result.team.probabilities)
    assert_equal 1.0, result.team.confidence
    assert_equal 1.0, result.urgent.probability
    assert_equal 1.0, result.mood.score
    assert_equal 'committed_answers', result.raw[:method]
  end

  def test_committed_answers_accept_yes_no_and_string_levels
    content = '{"answers":{"urgent":"no","mood":"0"}}'
    responder = ->(_prompt) { { content:, tokens: tokens } }
    result = with_engine(responder:) do
      RubyLLM::LLMJudge.judge('x', questions: { urgent: { type: :probability }, mood: { type: :score, levels: %w[Calm Angry] } },
                                   provider_options: { strategy: :committed })
    end

    assert_equal 0.0, result.urgent.probability
    assert_equal 0.0, result.mood.score
  end

  def test_committed_answer_outside_the_options_is_retried_then_raises
    responses = ['{"answers":{"team":"sales"}}', '{"answers":{"team":"billing"}}']
    prompts = []
    responder = lambda do |prompt|
      prompts << prompt
      { content: responses.shift || '{"answers":{"team":"sales"}}', tokens: tokens }
    end
    result = with_engine(responder:) do
      RubyLLM::LLMJudge.judge('x', questions: TEAM, provider_options: { strategy: :committed })
    end
    assert_equal :billing, result.team.choice
    assert_equal 2, result.raw[:attempts]
    assert_match(/must be one of \["billing", "technical"\]; got "sales"/, prompts.last)

    responder = ->(_prompt) { { content: '{"answers":{"team":"sales"}}', tokens: tokens } }
    assert_raises(RubyLLM::LLMJudge::Error) do
      with_engine(responder:) { RubyLLM::LLMJudge.judge('x', questions: TEAM, provider_options: { strategy: :committed }) }
    end
  end

  def test_one_call_prompt_puts_questions_before_state
    prompt = nil
    responder = lambda do |sent|
      prompt = sent
      { content: '{"answers":{"team":{"billing":0.2,"technical":0.8}}}', tokens: tokens }
    end
    with_engine(responder:) do
      RubyLLM::LLMJudge.judge('Refund please', questions: TEAM, provider_options: { strategy: :single_request })
    end

    assert_equal %w[questions state], JSON.parse(prompt.split("\n", 2).last).keys
  end

  def test_structured_output_must_be_boolean
    assert_raises(ArgumentError) do
      RubyLLM::LLMJudge.judge('x', questions: TEAM, provider_options: { structured_output: 'yes' })
    end
    error = assert_raises(ArgumentError) do
      RubyLLM::LLMJudge.judge('x', questions: TEAM, provider_options: { strategy: :guess })
    end
    assert_match(/:committed/, error.message)
  end

  def test_single_request_tie_is_retried_then_resolved
    responses = ['{"answers":{"team":{"billing":0.5,"technical":0.5}}}',
                 '{"answers":{"team":{"billing":0.3,"technical":0.7}}}']
    prompts = []
    responder = lambda do |prompt|
      prompts << prompt
      { content: responses.shift, tokens: tokens }
    end
    result = with_engine(responder:) do
      RubyLLM::LLMJudge.judge('x', questions: TEAM, provider_options: { strategy: :single_request })
    end

    assert_equal :technical, result.team.choice
    assert_equal 2, result.raw[:attempts]
    assert_match(/could not resolve the tie for team/, prompts.last)
  end

  def test_single_request_tie_raises_instead_of_picking_the_first_option
    responder = ->(_prompt) { { content: '{"answers":{"team":{"billing":0.5,"technical":0.5}}}', tokens: tokens } }
    error = assert_raises(RubyLLM::LLMJudge::Error) do
      with_engine(responder:) do
        RubyLLM::LLMJudge.judge('x', questions: TEAM, provider_options: { strategy: :single_request })
      end
    end
    assert_match(/could not resolve the tie for team/, error.message)
  end

  def test_single_request_tie_uses_the_first_option_when_asked
    calls = 0
    responder = lambda do |_prompt|
      calls += 1
      { content: '{"answers":{"team":{"billing":0.5,"technical":0.5}}}', tokens: tokens }
    end
    result = with_engine(responder:) do
      RubyLLM::LLMJudge.judge('x', questions: TEAM, provider_options: { strategy: :single_request, tie_breaker: :first })
    end

    assert_equal :billing, result.team.choice
    assert_equal 0.0, result.team.confidence
    assert_equal 1, calls
  end

  def test_even_probability_and_score_answers_are_not_ties
    content = '{"answers":{"urgent":{"true":0.5,"false":0.5},"mood":{"0":0.5,"1":0.5}}}'
    responder = ->(_prompt) { { content:, tokens: tokens } }
    result = with_engine(responder:) do
      RubyLLM::LLMJudge.judge('x', questions: { urgent: { type: :probability }, mood: { type: :score, levels: %w[Calm Angry] } },
                                   provider_options: { strategy: :single_request })
    end

    assert_in_delta 0.5, result.urgent.probability
    assert_in_delta 0.5, result.mood.score
  end

  def test_a_one_option_choice_is_fully_confident
    scorer = ->(_prompt) { { digit: 3, tokens: tokens } }
    result = with_engine(scorer:) do
      RubyLLM::LLMJudge.judge('x', questions: { only: { type: :choice, options: { answer: nil } } })
    end

    assert_equal :answer, result.only.choice
    assert_equal 1.0, result.only.confidence
  end

  def test_invalid_responses_raise_llm_judge_errors_without_a_response
    responder = ->(_prompt) { { content: 'not json', tokens: tokens } }
    error = assert_raises(RubyLLM::Error) do
      with_engine(responder:) do
        RubyLLM::LLMJudge.judge('x', questions: TEAM, provider_options: { strategy: :single_request, malformed_retries: 0 })
      end
    end
    assert_kind_of RubyLLM::LLMJudge::Error, error
    assert_nil error.response
    assert_match(/invalid JSON probabilities/, error.message)
  end
end
