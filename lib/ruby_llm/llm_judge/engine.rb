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
                     max_arms max_input_bytes strategy malformed_retries]
        raise ArgumentError, 'Unknown LLMJudge provider options' unless (options.keys - allowed).empty?

        @strategy = options.fetch(:strategy, :ratings).to_sym
        raise ArgumentError, 'strategy must be :ratings or :single_request' unless %i[ratings single_request].include?(@strategy)

        @scoring_provider = options.fetch(:scoring_provider, :openai).to_sym
        @scoring_model = model
        raise ArgumentError, 'A model is required' unless @scoring_model.is_a?(String) && !@scoring_model.empty?

        luna_defaults = @scoring_provider == :openai && @scoring_model == DEFAULT_MODEL
        @scoring_protocol = options.fetch(:scoring_protocol, luna_defaults ? :chat_completions : nil)
        @temperature = options.fetch(:temperature, luna_defaults ? 0 : nil)
        @max_output_tokens = options.fetch(:max_output_tokens, @strategy == :single_request ? 8192 : 4)
        @chat_provider_options = options.fetch(:chat_provider_options, default_chat_options(luna_defaults))
        @max_arms = options[:max_arms]
        @max_input_bytes = options[:max_input_bytes]
        @malformed_retries = options.fetch(:malformed_retries, 1)
        raise ArgumentError, 'chat_provider_options must be a Hash' unless @chat_provider_options.is_a?(Hash)
        raise ArgumentError, 'max_output_tokens must be positive' unless @max_output_tokens.is_a?(Integer) && @max_output_tokens.positive?
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
        answers = questions.values.to_h do |question|
          ratings = jobs.each_index.filter_map { |index|
            results[index].fetch(:digit) if jobs[index][:question] == question
          }
          [question.name, answer(question, softmax(ratings))]
        end
        tokens = RubyLLM::Tokens.aggregate(results.map { |result| result.fetch(:tokens) })
        RubyLLM::Judgment.new(
          answers:, model: model.id, tokens:,
          raw: { method: 'parallel_0_to_9_softmax', scoring_provider: @scoring_provider,
                 scoring_model: @scoring_model,
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
            return RubyLLM::Judgment.new(
              answers:, model: model.id,
              tokens: RubyLLM::Tokens.aggregate(attempts.map { |attempt| attempt.fetch(:tokens) }),
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
        parsed = JSON.parse(content)
        raise RubyLLM::Error, 'Scoring model returned a non-object response' unless parsed.is_a?(Hash)

        reported = parsed.fetch('answers')
        expected_questions = specs.map { |question, _| question.name.to_s }
        unless reported.is_a?(Hash) && reported.keys.sort == expected_questions.sort
          actual = reported.is_a?(Hash) ? reported.keys : reported.class.name
          raise RubyLLM::Error, "Question IDs must be #{expected_questions.inspect}; got #{actual.inspect}"
        end

        normalization = {}
        answers = specs.to_h do |question, options|
          distribution = reported.fetch(question.name.to_s)
          keys = options.map { |name, _| name.to_s }
          unless distribution.is_a?(Hash) && distribution.keys.sort == keys.sort
            actual = distribution.is_a?(Hash) ? distribution.keys : distribution.class.name
            raise RubyLLM::Error, "Option IDs for #{question.name} must be #{keys.inspect}; got #{actual.inspect}"
          end

          values = keys.map { |key| distribution.fetch(key) }
          unless values.all? { |value| value.is_a?(Numeric) && value.finite? && (0..1).cover?(value) }
            raise RubyLLM::Error, "Scoring model returned invalid probabilities for #{question.name}"
          end

          total = values.sum.to_f
          raise RubyLLM::Error, "Scoring model returned zero probability for #{question.name}" unless total.positive?

          normalization[question.name.to_s] = total
          [question.name, answer(question, values.map { |value| value / total })]
        end
        [answers, reported, normalization]
      rescue JSON::ParserError, KeyError, TypeError => error
        raise RubyLLM::Error, "Scoring model returned invalid JSON probabilities: #{error.message}"
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

      def run(jobs)
        queue = Queue.new
        jobs.each_with_index { |job, index| queue << [index, job] }
        results = Array.new(jobs.size)
        workers = Array.new([jobs.size, MAX_WORKERS].min) do
          Thread.new do
            Thread.current.report_on_exception = false
            loop do
              begin
                index, job = queue.pop(true)
              rescue ThreadError
                break
              end
              results[index] = yield job
            end
          end
        end
        workers.each(&:join)
        workers.each(&:value)
        results
      end

      def default_chat_options(luna_defaults)
        return {} unless @scoring_provider == :openai

        luna_defaults ? { store: false, reasoning_effort: 'none' } : { store: false }
      end

      def score_with_model(prompt)
        chat = scoring_chat
        response = chat.ask(prompt)
        digit = response.content.to_s.strip
        raise RubyLLM::Error, 'Scoring model returned no single digit' unless /\A[0-9]\z/.match?(digit)

        { digit: digit.to_i, tokens: response.tokens }
      end

      def respond_with_model(prompt)
        response = scoring_chat(instructions: SINGLE_REQUEST_INSTRUCTIONS).ask(prompt)
        { content: response.content.to_s, tokens: response.tokens }
      end

      def scoring_chat(instructions: SYSTEM_INSTRUCTIONS)
        context = RubyLLM::Context.new(@config)
        chat = context.chat(model: @scoring_model, provider: @scoring_provider,
                            protocol: @scoring_protocol, assume_model_exists: true)
        chat.with_instructions(instructions)
        chat.with_temperature(@temperature) unless @temperature.nil?
        chat.with_max_output_tokens(@max_output_tokens)
        chat.with_provider_options(@chat_provider_options)
        chat
      end

      def answer(question, probabilities)
        case question.type
        when :probability
          RubyLLM::Probability.new(probability: probabilities.first)
        when :choice
          names = question.criteria.keys
          distribution = names.zip(probabilities).to_h
          RubyLLM::Choice.new(choice: names[probabilities.index(probabilities.max)], probabilities: distribution,
                              confidence: concentration(probabilities))
        when :score
          RubyLLM::Score.new(score: probabilities.each_with_index.sum { |probability, index| probability * index },
                             levels: question.criteria,
                             probabilities: probabilities.each_with_index.to_h { |probability, index| [index, probability] },
                             confidence: concentration(probabilities))
        end
      end

      def softmax(ratings)
        peak = ratings.max
        weights = ratings.map { |rating| Math.exp(rating - peak) }
        weights.map { |weight| weight / weights.sum }
      end

      def concentration(probabilities)
        return 0.0 if probabilities.one?
        return 0.0 if probabilities.count(probabilities.max) > 1

        entropy = -probabilities.sum { |probability| probability.zero? ? 0.0 : probability * Math.log(probability) }
        [[1.0 - entropy / Math.log(probabilities.size), 0.0].max, 1.0].min
      end
    end
  end
end
