# frozen_string_literal: true

require 'json'

module RubyLLM
  module LLMJudge
    class Engine
      MAX_WORKERS = 6
      SYSTEM_INSTRUCTIONS = 'Return exactly one ASCII digit 0-9. 9 means very likely to be the correct answer; 0 means very unlikely. No explanation.'
      SINGLE_REQUEST_INSTRUCTIONS = 'Answer all questions using only a JSON object with an "answers" field. ' \
                                    'For each question, return an object mapping every supplied option ID to a ' \
                                    'probability between 0 and 1. Include every option exactly once and make ' \
                                    'each question\'s probabilities sum to 1. Evaluate each question independently ' \
                                    'against the same state. Return no explanations or markdown.'

      def initialize(config:, model: DEFAULT_MODEL, provider_options: {}, scorer: nil, responder: nil)
        @config = config
        options = provider_options.transform_keys(&:to_sym)
        allowed = %i[scoring_provider scoring_protocol temperature max_output_tokens chat_provider_options
                     max_arms max_input_bytes strategy malformed_retries tie_breaker tie_break_max_output_tokens
                     max_workers]
        unknown = options.keys - allowed
        raise ArgumentError, "Unknown LLMJudge provider options: #{unknown.join(', ')}" unless unknown.empty?

        @strategy = options.fetch(:strategy, :ratings).to_sym
        raise ArgumentError, 'strategy must be :ratings or :single_request' unless %i[ratings single_request].include?(@strategy)
        @tie_breaker = options.fetch(:tie_breaker, :single_request).to_sym
        raise ArgumentError, 'tie_breaker must be :single_request or :first' unless %i[single_request first].include?(@tie_breaker)

        @scoring_provider = options.fetch(:scoring_provider, :openai).to_sym
        @scoring_model = model
        raise ArgumentError, 'A model is required' unless @scoring_model.is_a?(String) && !@scoring_model.empty?

        luna_defaults = @scoring_provider == :openai && @scoring_model == DEFAULT_MODEL
        @scoring_protocol = options.fetch(:scoring_protocol, luna_defaults ? :chat_completions : nil)
        # Before 2.1, RubyLLM chats use each provider's one chat API (Chat Completions for OpenAI).
        if !NATIVE && ![nil, :chat_completions].include?(@scoring_protocol&.to_sym)
          raise ArgumentError, 'scoring_protocol requires RubyLLM 2.1'
        end
        @temperature = options.fetch(:temperature, luna_defaults ? 0 : nil)
        @max_output_tokens = options.fetch(:max_output_tokens, @strategy == :single_request ? 8192 : 4)
        @tie_break_max_output_tokens = options.fetch(:tie_break_max_output_tokens, 8192)
        chat_provider_options = options.fetch(:chat_provider_options, {})
        raise ArgumentError, 'chat_provider_options must be a Hash' unless chat_provider_options.is_a?(Hash)

        # Merged over the defaults, so tuning one option keeps the others (such as disabled reasoning).
        @chat_provider_options = deep_merge(default_chat_options(luna_defaults), chat_provider_options)
        @max_arms = options[:max_arms]
        @max_input_bytes = options[:max_input_bytes]
        @malformed_retries = options.fetch(:malformed_retries, 1)
        @max_workers = options.fetch(:max_workers, MAX_WORKERS)
        raise ArgumentError, 'max_workers must be a positive integer' unless @max_workers.is_a?(Integer) && @max_workers.positive?
        raise ArgumentError, 'max_output_tokens must be positive' unless @max_output_tokens.is_a?(Integer) && @max_output_tokens.positive?
        unless @tie_break_max_output_tokens.is_a?(Integer) && @tie_break_max_output_tokens.positive?
          raise ArgumentError, 'tie_break_max_output_tokens must be positive'
        end
        unless [@max_arms, @max_input_bytes].all? { |limit| limit.nil? || (limit.is_a?(Integer) && limit.positive?) }
          raise ArgumentError, 'LLMJudge limits must be positive integers'
        end
        unless @malformed_retries.is_a?(Integer) && @malformed_retries >= 0
          raise ArgumentError, 'malformed_retries must be a nonnegative integer'
        end

        @scorer = scorer || method(:score_with_model)
        @responder = responder || method(:respond_with_model)
      end

      def judge(input, questions:, model:)
        return judge_single_request(input, questions, model) if @strategy == :single_request

        jobs = build_jobs(input, questions)
        results = run(jobs) { |job| @scorer.call(job[:prompt]) }
        tie_breaks = []
        answers = questions.values.to_h do |question|
          ratings = jobs.each_index.filter_map { |index|
            results[index].fetch(:digit) if jobs[index][:question] == question
          }
          chosen = answer(question, softmax(ratings))
          if question.type == :choice && ratings.count(ratings.max) > 1 && @tie_breaker == :single_request
            # Raises if the one-call judgment also ties, after its corrective retry.
            judgment = judge_single_request(input, { question.name => question }, model)
            chosen = judgment.answers.fetch(question.name)
            tie_breaks << { question: question.name, ratings:, judgment: }
          end
          [question.name, chosen]
        end
        tokens = aggregate_tokens(results.map { |result| result.fetch(:tokens) } +
                                  tie_breaks.map { |item| item[:judgment].tokens })
        Types::Judgment.new(
          answers:, model: model.id, tokens:,
          raw: { method: 'parallel_0_to_9_softmax', scoring_provider: @scoring_provider,
                 scoring_model: @scoring_model,
                 tie_breaks: tie_breaks.map { |item|
                   { question: item[:question], ratings: item[:ratings],
                     probabilities: item[:judgment].answers.fetch(item[:question]).probabilities,
                     attempts: item[:judgment].raw[:attempts] }
                 },
                 ratings: jobs.each_with_index.map { |job, index|
                   { question: job[:question].name, option: job[:name], digit: results[index][:digit] }
                 } }
        )
      end

      private

      def judge_single_request(input, questions, model)
        specs = validated_options(input, questions)
        original_prompt = single_request_prompt(input, specs)
        prompt = original_prompt
        attempts = []
        loop do
          result = @responder.call(prompt)
          attempts << result
          begin
            answers, reported, normalization = parse_single_request(result.fetch(:content), specs)
            return Types::Judgment.new(
              answers:, model: model.id,
              tokens: aggregate_tokens(attempts.map { |attempt| attempt.fetch(:tokens) }),
              raw: { method: 'single_request_probabilities', scoring_provider: @scoring_provider,
                     scoring_model: @scoring_model, reported_probabilities: reported,
                     reported_totals: normalization, attempts: attempts.size }
            )
          rescue RubyLLM::Error => error
            raise if attempts.size > @malformed_retries

            prompt = "#{original_prompt}\n\nThe previous answer was invalid: #{error.message}. " \
                     "Previous answer: #{result.fetch(:content).to_s[0, 4000]}\n" \
                     'Return a complete corrected JSON object with every question and option.'
          end
        end
      end

      def parse_single_request(content, specs)
        parsed = JSON.parse(strip_code_fence(content))
        raise Error, 'Scoring model returned a non-object response' unless parsed.is_a?(Hash)

        reported = parsed.fetch('answers')
        # Some models mirror the prompt's question list: [{"id": {...}}, ...].
        if reported.is_a?(Array) && reported.all? { |item| item.is_a?(Hash) }
          ids = reported.flat_map(&:keys)
          reported = reported.reduce({}, :merge) if ids.uniq.size == ids.size
        end
        expected_questions = specs.map { |question, _| question.name.to_s }
        unless reported.is_a?(Hash) && reported.keys.sort == expected_questions.sort
          actual = reported.is_a?(Hash) ? reported.keys : reported.class.name
          raise Error, "Question IDs must be #{expected_questions.inspect}; got #{actual.inspect}"
        end

        normalization = {}
        answers = specs.to_h do |question, options|
          distribution = reported.fetch(question.name.to_s)
          keys = options.map { |name, _| name.to_s }
          unless distribution.is_a?(Hash) && distribution.keys.sort == keys.sort
            actual = distribution.is_a?(Hash) ? distribution.keys : distribution.class.name
            raise Error, "Option IDs for #{question.name} must be #{keys.inspect}; got #{actual.inspect}"
          end

          values = keys.map { |key| distribution.fetch(key) }
          unless values.all? { |value| value.is_a?(Numeric) && value.finite? && (0..1).cover?(value) }
            raise Error, "Scoring model returned invalid probabilities for #{question.name}"
          end

          total = values.sum.to_f
          raise Error, "Scoring model returned zero probability for #{question.name}" unless total.positive?

          # A tied Choice would otherwise select whichever option was listed first.
          if question.type == :choice && @tie_breaker == :single_request && values.count(values.max) > 1
            raise Error, "Scoring model could not resolve the tie for #{question.name}; " \
                         'one option must have the highest probability'
          end

          normalization[question.name.to_s] = total
          [question.name, answer(question, values.map { |value| value / total })]
        end
        [answers, reported, normalization]
      rescue JSON::ParserError, KeyError, TypeError => error
        raise Error, "Scoring model returned invalid JSON probabilities: #{error.message}"
      end

      def single_request_prompt(input, specs)
        request = {
          state: input,
          questions: specs.map do |question, options|
            { id: question.name, type: question.type, instructions: question.instructions,
              options: options.map { |name, description| { id: name.to_s, description: } } }
          end
        }
        "Evaluate this decision request. Return only the requested JSON object.\n#{JSON.generate(request)}"
      end

      def build_jobs(input, questions)
        jobs = validated_options(input, questions).flat_map do |question, options|
          options.map do |name, description|
            { question:, name:, description:, prompt: prompt(input, question.instructions, name, description) }
          end
        end
        jobs
      end

      def validated_options(input, questions)
        if @max_input_bytes
          input_bytes = serialize(input).bytesize + questions.values.sum do |question|
            serialize(question.instructions).bytesize + serialize(question.criteria).bytesize
          end
          raise ArgumentError, "LLMJudge input exceeds #{@max_input_bytes} bytes" if input_bytes > @max_input_bytes
        end

        specs = questions.values.map { |question| [question, options_for(question)] }
        arms = specs.sum { |_, options| options.size }
        raise ArgumentError, "LLMJudge exceeds #{@max_arms} scoring arms" if @max_arms && arms > @max_arms

        specs
      end

      def options_for(question)
        case question.type
        when :probability
          criteria = question.criteria || {}
          yes_key = criteria.keys.find { |key| %w[yes true].include?(key.to_s) }
          no_key = criteria.keys.find { |key| %w[no false].include?(key.to_s) }
          yes = yes_key ? criteria[yes_key] : 'Yes, the condition holds'
          no = no_key ? criteria[no_key] : 'No, the condition does not hold'
          [['true', yes], ['false', no]]
        when :choice
          raise ArgumentError, 'A choice needs 1–255 options' unless (1..255).cover?(question.criteria.size)

          question.criteria.to_a
        when :score
          raise ArgumentError, 'A score needs 2–10 levels' unless (2..10).cover?(question.criteria.size)

          question.criteria.each_with_index.map { |description, index| [index, description] }
        else
          raise ArgumentError, "Unsupported question type: #{question.type}"
        end
      end

      def prompt(input, instructions, name, description)
        "Question: #{serialize(instructions || 'Which answer best applies?')}\n" \
          "State: #{serialize(input)}\n\n" \
          'Output a single number between 0 and 9 to tell how likely it is that the correct answer is: ' \
          "#{name} — #{serialize(description)}"
      end

      def serialize(value)
        value.is_a?(String) ? value : JSON.generate(value)
      end

      # Runs jobs on up to @max_workers threads. After a job fails, no new jobs
      # start; calls already in flight finish, then the first error is raised.
      def run(jobs)
        queue = Queue.new
        jobs.each_with_index { |job, index| queue << [index, job] }
        results = Array.new(jobs.size)
        errors = Queue.new
        workers = Array.new([jobs.size, @max_workers].min) do
          Thread.new do
            while errors.empty?
              begin
                index, job = queue.pop(true)
              rescue ThreadError
                break
              end
              begin
                results[index] = yield job
              rescue StandardError => error
                errors << error
              end
            end
          end
        end
        workers.each(&:join)
        raise errors.pop unless errors.empty?

        results
      end

      # Some models wrap JSON in a Markdown code fence despite the instructions.
      def strip_code_fence(content)
        content.to_s.strip.sub(/\A```(?:json)?[ \t]*\n?/i, '').sub(/\n?```\z/, '')
      end

      def deep_merge(base, overrides)
        base.merge(overrides) do |_key, old, new|
          old.is_a?(Hash) && new.is_a?(Hash) ? deep_merge(old, new) : new
        end
      end

      def default_chat_options(luna_defaults)
        return {} unless @scoring_provider == :openai

        luna_defaults ? { store: false, reasoning_effort: 'none' } : { store: false }
      end

      def score_with_model(prompt)
        attempts = []
        loop do
          request = attempts.empty? ? prompt : "#{prompt}\n\nYour previous answer was invalid. Return exactly one ASCII digit 0-9."
          response = scoring_chat.ask(request)
          attempts << response
          digit = response.content.to_s.strip
          if /\A[0-9]\z/.match?(digit)
            return { digit: digit.to_i, tokens: aggregate_tokens(attempts.map(&:tokens)) }
          end
          raise Error, 'Scoring model returned no single digit' if attempts.size > @malformed_retries
        end
      end

      def respond_with_model(prompt)
        limit = @strategy == :ratings ? @tie_break_max_output_tokens : @max_output_tokens
        response = scoring_chat(instructions: SINGLE_REQUEST_INSTRUCTIONS, max_output_tokens: limit).ask(prompt)
        { content: response.content.to_s, tokens: response.tokens }
      end

      def scoring_chat(instructions: SYSTEM_INSTRUCTIONS, max_output_tokens: @max_output_tokens)
        context = RubyLLM::Context.new(@config)
        chat = if NATIVE
                 context.chat(model: @scoring_model, provider: @scoring_provider,
                              protocol: @scoring_protocol, assume_model_exists: true)
               else
                 context.chat(model: @scoring_model, provider: @scoring_provider, assume_model_exists: true)
               end
        chat.with_instructions(instructions)
        chat.with_temperature(@temperature) unless @temperature.nil?
        if NATIVE
          chat.with_max_output_tokens(max_output_tokens)
          chat.with_provider_options(deep_compact(@chat_provider_options))
        else
          chat.with_params(**deep_compact(deep_merge(max_output_tokens_param(max_output_tokens), @chat_provider_options)))
        end
        chat
      end

      # A nil in chat_provider_options removes that field: a default, or before 2.1
      # the output limit field. A hash emptied by removal is removed too.
      def deep_compact(hash)
        hash.each_with_object({}) do |(key, value), compacted|
          next if value.nil?

          if value.is_a?(Hash) && !value.empty?
            value = deep_compact(value)
            next if value.empty?
          end
          compacted[key] = value
        end
      end

      # The request field each provider reads for the output limit, as RubyLLM 2.1 renders it.
      def max_output_tokens_param(limit)
        case @scoring_provider
        when :openai, :azure then { max_completion_tokens: limit }
        when :gemini, :vertexai then { generationConfig: { maxOutputTokens: limit } }
        when :bedrock then { inferenceConfig: { maxTokens: limit } }
        else { max_tokens: limit }
        end
      end

      def aggregate_tokens(tokens)
        NATIVE ? RubyLLM::Tokens.aggregate(tokens) : Legacy.aggregate_tokens(tokens)
      end

      def answer(question, probabilities)
        case question.type
        when :probability
          Types::Probability.new(probability: probabilities.first)
        when :choice
          names = question.criteria.keys
          distribution = names.zip(probabilities).to_h
          Types::Choice.new(choice: names[probabilities.index(probabilities.max)], probabilities: distribution,
                              confidence: concentration(probabilities))
        when :score
          Types::Score.new(score: probabilities.each_with_index.sum { |probability, index| probability * index },
                             levels: question.criteria,
                             probabilities: probabilities.each_with_index.to_h { |probability, index| [index, probability] },
                             confidence: concentration(probabilities))
        end
      end

      def softmax(ratings)
        peak = ratings.max
        weights = ratings.map { |rating| Math.exp(rating - peak) }
        total = weights.sum
        weights.map { |weight| weight / total }
      end

      def concentration(probabilities)
        return 1.0 if probabilities.size == 1
        return 0.0 if probabilities.count(probabilities.max) > 1

        entropy = -probabilities.sum { |probability| probability.zero? ? 0.0 : probability * Math.log(probability) }
        [[1.0 - entropy / Math.log(probabilities.size), 0.0].max, 1.0].min
      end
    end
  end
end
