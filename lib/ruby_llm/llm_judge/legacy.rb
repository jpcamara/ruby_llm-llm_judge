# frozen_string_literal: true

module RubyLLM
  module LLMJudge
    # Stand-ins for RubyLLM 2.1's Judge types, used when RubyLLM predates the
    # Judge API. They expose the same readers, so code written against
    # RubyLLM::LLMJudge.judge keeps working after upgrading.
    module Legacy
      Model = Data.define(:id)

      class Question
        CRITERIA_KEYS = { probability: :criteria, choice: :options, score: :levels }.freeze

        attr_reader :name, :type, :instructions, :criteria

        def self.from_h(name, definition)
          raise ArgumentError, 'Each question must be a Hash' unless definition.is_a?(Hash)

          definition = definition.transform_keys(&:to_sym)
          type = definition[:type]&.to_sym
          key = CRITERIA_KEYS.fetch(type) { raise ArgumentError, "Unknown judgment type: #{type.inspect}" }
          extra = definition.keys - [:type, :instructions, key]
          raise ArgumentError, "Unknown question options: #{extra.join(', ')}" unless extra.empty?

          new(name, type:, instructions: definition[:instructions], criteria: definition[key])
        end

        def initialize(name, type:, instructions:, criteria:)
          raise ArgumentError, 'A question name must be a String or Symbol' unless name.is_a?(String) || name.is_a?(Symbol)

          @name = name
          @type = type
          @instructions = instructions
          @criteria = criteria
          validate!
          freeze
        end

        private

        def validate!
          case type
          when :probability
            return if criteria.nil?
            unless criteria.is_a?(Hash) && (criteria.keys.map(&:to_s) - %w[yes no true false]).empty?
              raise ArgumentError, 'Probability criteria must describe yes and no'
            end
          when :choice
            raise ArgumentError, 'A choice needs a nonempty Hash of options' unless criteria.is_a?(Hash) && !criteria.empty?
          when :score
            unless criteria.is_a?(Array) && criteria.size >= 2 && criteria.none?(&:nil?)
              raise ArgumentError, 'A score needs at least two non-nil levels'
            end
          end
        end
      end

      class Probability
        attr_reader :probability

        def initialize(probability:)
          @probability = probability
          freeze
        end

        def type = :probability
        def to_h = { type:, probability: }
      end

      class Choice
        attr_reader :choice, :probabilities, :confidence

        def initialize(choice:, probabilities:, confidence:)
          @choice = choice
          @probabilities = probabilities.dup.freeze
          @confidence = confidence
          freeze
        end

        def type = :choice
        def to_h = { type:, choice:, probabilities:, confidence: }
      end

      class Score
        attr_reader :score, :levels, :probabilities, :confidence

        def initialize(score:, levels:, probabilities:, confidence:)
          @score = score
          @levels = levels
          @probabilities = probabilities.dup.freeze
          @confidence = confidence
          freeze
        end

        def type = :score
        def to_h = { type:, score:, levels:, probabilities:, confidence: }
      end

      class Judgment
        include Enumerable

        attr_reader :answers, :model, :tokens, :raw

        def initialize(answers:, model:, tokens:, raw: nil)
          @answers = answers.dup.freeze
          @answer_keys = answers.keys.to_h { |key| [key.to_s, key] }.freeze
          @model = model
          @tokens = tokens
          @raw = raw
        end

        def [](name)
          answers[@answer_keys[name.to_s]]
        end

        def fetch(name)
          answers.fetch(@answer_keys.fetch(name.to_s))
        end

        def each(&)
          answers.each(&)
        end

        def to_h
          { model:, answers: answers.transform_values(&:to_h), tokens: tokens.to_h }
        end

        private

        def method_missing(name, *args, &block)
          return super unless args.empty? && !block && @answer_keys.key?(name.to_s)

          self[name]
        end

        def respond_to_missing?(name, include_private = false)
          @answer_keys.key?(name.to_s) || super
        end
      end

      module_function

      def aggregate_tokens(tokens)
        tokens = tokens.compact
        sum = ->(reader) { tokens.sum { |token| token.public_send(reader) || 0 } }
        RubyLLM::Tokens.new(input: sum.(:input), output: sum.(:output))
      end
    end
  end
end
