# frozen_string_literal: true

module RubyLLM
  module LLMJudge
    class Provider < RubyLLM::Provider
      def api_base
        'http://127.0.0.1'
      end

      def judge(input, questions:, model:, provider_options: {})
        Engine.new(config:, model: model.id, provider_options:).judge(input, questions:, model:)
      end

      def self.assume_models_exist?
        true
      end
    end
  end
end
