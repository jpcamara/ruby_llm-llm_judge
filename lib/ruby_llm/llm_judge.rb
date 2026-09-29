# frozen_string_literal: true

require 'ruby_llm'
require_relative 'llm_judge/version'

module RubyLLM
  module LLMJudge
    DEFAULT_MODEL = 'gpt-6-luna'

    # RubyLLM 2.1 added the Judge API. Earlier versions run the engine directly
    # and return Legacy stand-ins with the same readers.
    NATIVE = defined?(RubyLLM::Judge) ? true : false

    # Raised for invalid scoring responses. RubyLLM::Error takes (response, message)
    # before 1.16 and (message, response:) on main, so build it for either.
    class Error < RubyLLM::Error
      def initialize(message = nil)
        if RubyLLM::Error.instance_method(:initialize).parameters.include?(%i[key response])
          super(message)
        else
          super(nil, message)
        end
      end
    end
  end
end

require_relative 'llm_judge/legacy' unless RubyLLM::LLMJudge::NATIVE
require_relative 'llm_judge/engine'
require_relative 'llm_judge/provider' if RubyLLM::LLMJudge::NATIVE

module RubyLLM
  module LLMJudge
    # Answer and judgment classes: RubyLLM's own on 2.1+, Legacy otherwise.
    Types = NATIVE ? RubyLLM : Legacy

    def self.judge(input, questions:, model: DEFAULT_MODEL, **options)
      if NATIVE
        return RubyLLM.judge(input, questions:, model:, provider: :llm_judge,
                                    assume_model_exists: true, **options)
      end

      provider_options = options.delete(:provider_options) || {}
      context = options.delete(:context)
      raise ArgumentError, "Unsupported before RubyLLM 2.1: #{options.keys.join(', ')}" unless options.empty?

      built = questions.to_h { |name, definition| [name.to_s, Legacy::Question.from_h(name, definition)] }
      Engine.new(config: context&.config || RubyLLM.config, model:, provider_options:)
            .judge(input, questions: built, model: Legacy::Model.new(id: model))
    end
  end
end

RubyLLM::Provider.register(:llm_judge, RubyLLM::LLMJudge::Provider) if RubyLLM::LLMJudge::NATIVE
