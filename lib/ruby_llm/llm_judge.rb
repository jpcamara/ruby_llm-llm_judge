# frozen_string_literal: true

require 'ruby_llm'
require_relative 'llm_judge/version'
require_relative 'llm_judge/engine'
require_relative 'llm_judge/provider'

module RubyLLM
  module LLMJudge
    DEFAULT_MODEL = 'gpt-6-luna'

    def self.judge(input, questions:, model: DEFAULT_MODEL, **options)
      RubyLLM.judge(input, questions:, model:, provider: :llm_judge,
                   assume_model_exists: true, **options)
    end
  end
end

RubyLLM::Provider.register(:llm_judge, RubyLLM::LLMJudge::Provider)
