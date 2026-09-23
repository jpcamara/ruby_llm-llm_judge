# frozen_string_literal: true

require 'json'

module RubyLLM
  module LLMJudge
    class Engine
      MAX_WORKERS = 6
      SYSTEM_INSTRUCTIONS = 'Return exactly one ASCII digit 0-9. 9 means very likely to be the correct answer; 0 means very unlikely. No explanation.'

      def initialize(config:, model: DEFAULT_MODEL, provider_options: {}, scorer: nil)
        @config = config
        options = provider_options.transform_keys(&:to_sym)
        allowed = %i[scoring_provider scoring_protocol temperature max_output_tokens chat_provider_options
                     max_arms max_input_bytes]
        raise ArgumentError, 'Unknown LLMJudge provider options' unless (options.keys - allowed).empty?

        @scoring_provider = options.fetch(:scoring_provider, :openai).to_sym
        @scoring_model = model
        raise ArgumentError, 'A model is required' unless @scoring_model.is_a?(String) && !@scoring_model.empty?

        luna_defaults = @scoring_provider == :openai && @scoring_model == DEFAULT_MODEL
        @scoring_protocol = options.fetch(:scoring_protocol, luna_defaults ? :chat_completions : nil)
        @temperature = options.fetch(:temperature, luna_defaults ? 0 : nil)
        @max_output_tokens = options.fetch(:max_output_tokens, 4)
        @chat_provider_options = options.fetch(:chat_provider_options, default_chat_options(luna_defaults))
        @max_arms = options[:max_arms]
        @max_input_bytes = options[:max_input_bytes]
        raise ArgumentError, 'chat_provider_options must be a Hash' unless @chat_provider_options.is_a?(Hash)
        raise ArgumentError, 'max_output_tokens must be positive' unless @max_output_tokens.is_a?(Integer) && @max_output_tokens.positive?
        unless [@max_arms, @max_input_bytes].all? { |limit| limit.nil? || (limit.is_a?(Integer) && limit.positive?) }
          raise ArgumentError, 'LLMJudge limits must be positive integers'
        end

        @scorer = scorer || method(:score_with_model)
      end

      def judge(input, questions:, model:)
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

      def build_jobs(input, questions)
        if @max_input_bytes
          input_bytes = serialize(input).bytesize + questions.values.sum do |question|
            serialize(question.instructions).bytesize + serialize(question.criteria).bytesize
          end
          raise ArgumentError, "LLMJudge input exceeds #{@max_input_bytes} bytes" if input_bytes > @max_input_bytes
        end

        jobs = questions.values.flat_map do |question|
          options_for(question).map do |name, description|
            { question:, name:, description:, prompt: prompt(input, question.instructions, name, description) }
          end
        end
        raise ArgumentError, "LLMJudge exceeds #{@max_arms} scoring arms" if @max_arms && jobs.size > @max_arms

        jobs
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

      def scoring_chat
        context = RubyLLM::Context.new(@config)
        chat = context.chat(model: @scoring_model, provider: @scoring_provider,
                            protocol: @scoring_protocol, assume_model_exists: true)
        chat.with_instructions(SYSTEM_INSTRUCTIONS)
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
