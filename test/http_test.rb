# frozen_string_literal: true

# Sends real RubyLLM chat requests to stubbed HTTP endpoints, so the request
# bodies and response handling are checked on every supported RubyLLM.

require 'minitest/autorun'
require 'webmock/minitest'
require 'json'
require 'ruby_llm/llm_judge'

class HTTPTest < Minitest::Test
  OPENAI = 'https://api.openai.com/v1/chat/completions'
  OPENROUTER = 'https://openrouter.ai/api/v1/chat/completions'
  TEAM = { team: { type: :choice, instructions: 'Team?', options: { billing: 'Money', technical: 'Software' } } }.freeze

  def setup
    @config = RubyLLM.config.dup
    RubyLLM.configure do |config|
      config.openai_api_key = 'test-openai'
      config.openrouter_api_key = 'test-openrouter'
      config.max_retries = 0
    end
    @requests = Queue.new
  end

  def teardown
    %i[openai_api_key openrouter_api_key max_retries].each do |key|
      RubyLLM.config.public_send(:"#{key}=", @config.public_send(key))
    end
  end

  # Records each request body and answers with content from the block.
  def stub_chat(url)
    stub_request(:post, url).to_return do |request|
      body = JSON.parse(request.body)
      @requests << body
      content = yield(body['messages'].last['content'], body)
      { status: 200, headers: { 'Content-Type' => 'application/json' },
        body: JSON.generate(id: 'chatcmpl-1', object: 'chat.completion', model: body['model'],
                            choices: [{ index: 0, message: { role: 'assistant', content: }, finish_reason: 'stop' }],
                            usage: { prompt_tokens: 20, completion_tokens: 2, total_tokens: 22 }) }
    end
  end

  def requests = Array.new(@requests.size) { @requests.pop }

  def assert_instructions(body, instructions)
    system = body['messages'].first
    assert_includes %w[system developer], system['role']
    assert_equal instructions, system['content']
  end

  def test_luna_ratings_request
    stub_chat(OPENAI) { |prompt, _| prompt.end_with?('technical — Software') ? '8' : '2' }
    result = RubyLLM::LLMJudge.judge('Refund please', questions: TEAM)

    assert_equal :technical, result.team.choice
    assert_equal 40, result.tokens.input
    assert_equal 4, result.tokens.output
    bodies = requests
    assert_equal 2, bodies.size
    bodies.each do |body|
      assert_equal 'gpt-6-luna', body['model']
      assert_equal 0, body['temperature']
      assert_equal 4, body['max_completion_tokens']
      assert_equal false, body['store']
      assert_equal 'none', body['reasoning_effort']
      assert_instructions(body, RubyLLM::LLMJudge::Engine::SYSTEM_INSTRUCTIONS)
      assert_match(/\AQuestion: Team\?\nState: Refund please\n/, body['messages'].last['content'])
    end
  end

  def test_luna_single_request
    stub_chat(OPENAI) { '{"answers":{"team":{"billing":0.1,"technical":0.9}}}' }
    result = RubyLLM::LLMJudge.judge('App crashes', questions: TEAM,
                                                   provider_options: { strategy: :single_request, max_output_tokens: 512 })

    assert_equal :technical, result.team.choice
    body = requests.first
    assert_equal 512, body['max_completion_tokens']
    assert_instructions(body, RubyLLM::LLMJudge::Engine::SINGLE_REQUEST_INSTRUCTIONS)
    request = JSON.parse(body['messages'].last['content'].split("\n", 2).last)
    assert_equal 'App crashes', request['state']
    assert_equal %w[billing technical], request['questions'].first['options'].map { |option| option['id'] }
  end

  def test_chat_provider_options_are_merged_over_the_luna_defaults
    stub_chat(OPENAI) { '7' }
    RubyLLM::LLMJudge.judge('x', questions: { urgent: { type: :probability } },
                                 provider_options: { chat_provider_options: { service_tier: 'flex', store: true } })

    requests.each do |body|
      assert_equal 'flex', body['service_tier']
      assert_equal true, body['store']
      assert_equal 'none', body['reasoning_effort']
    end
  end

  def test_nil_chat_provider_options_remove_default_fields
    stub_chat(OPENAI) { '7' }
    RubyLLM::LLMJudge.judge('x', questions: { urgent: { type: :probability } },
                                 provider_options: { chat_provider_options: { reasoning_effort: nil } })

    requests.each do |body|
      refute body.key?('reasoning_effort')
      assert_equal false, body['store']
    end
  end

  def test_nil_nested_options_remove_hashes_they_empty
    stub_chat(OPENROUTER) { '7' }
    RubyLLM::LLMJudge.judge('x', model: 'openai/gpt-6-luna', questions: { urgent: { type: :probability } },
                                 provider_options: { scoring_provider: :openrouter,
                                                     chat_provider_options: { reasoning: { effort: nil },
                                                                              provider: { sort: 'latency', only: nil },
                                                                              metadata: {} } })

    requests.each do |body|
      refute body.key?('reasoning')
      assert_equal({ 'sort' => 'latency' }, body['provider'])
      assert_equal({}, body['metadata'])
    end
  end

  def test_nil_chat_provider_options_can_rename_the_output_limit_field
    skip 'RubyLLM 2.1 renders the output limit for the scoring protocol' if RubyLLM::LLMJudge::NATIVE

    stub_chat(OPENAI) { '{"answers":{"urgent":{"true":0.8,"false":0.2}}}' }
    RubyLLM::LLMJudge.judge('x', questions: { urgent: { type: :probability } },
                                 provider_options: { strategy: :single_request,
                                                     chat_provider_options: { max_completion_tokens: nil,
                                                                              max_output_tokens: 256 } })

    body = requests.first
    refute body.key?('max_completion_tokens')
    assert_equal 256, body['max_output_tokens']
  end

  def test_other_providers_use_their_own_output_field_and_no_luna_defaults
    stub_chat(OPENROUTER) { "```json\n{\"answers\":{\"team\":{\"billing\":0.7,\"technical\":0.3}}}\n```" }
    result = RubyLLM::LLMJudge.judge('x', model: 'anthropic/claude-haiku-4.5', questions: TEAM,
                                          provider_options: { scoring_provider: :openrouter, strategy: :single_request,
                                                              max_output_tokens: 300,
                                                              chat_provider_options: { provider: { sort: 'latency' } } })

    assert_equal :billing, result.team.choice
    body = requests.first
    assert_equal 'anthropic/claude-haiku-4.5', body['model']
    assert_equal 300, body['max_tokens']
    assert_equal({ 'sort' => 'latency' }, body['provider'])
    refute body.key?('temperature')
    refute body.key?('reasoning_effort')
    refute body.key?('store')
  end

  def test_malformed_digit_is_retried_over_http
    answers = Queue.new
    %w[seven 6].each { |answer| answers << answer }
    stub_chat(OPENAI) { answers.pop }
    result = RubyLLM::LLMJudge.judge('x', questions: { only: { type: :choice, options: { yes: nil } } })

    bodies = requests
    assert_equal 2, bodies.size
    assert_match(/previous answer was invalid/, bodies.last['messages'].last['content'])
    assert_equal 40, result.tokens.input
  end

  def test_provider_errors_are_ruby_llm_errors
    stub_request(:post, OPENAI).to_return(status: 500, body: '{"error":{"message":"overloaded"}}',
                                          headers: { 'Content-Type' => 'application/json' })

    assert_raises(RubyLLM::Error) { RubyLLM::LLMJudge.judge('x', questions: TEAM) }
  end
end
