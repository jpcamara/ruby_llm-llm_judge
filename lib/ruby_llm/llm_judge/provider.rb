# frozen_string_literal: true

module RubyLLM
  module LLMJudge
    class Provider < RubyLLM::Provider
      def api_base
        'http://127.0.0.1'
      end

      # RubyLLM passes images as +with:+; they are not supported yet.
      def judge(input, questions:, model:, with: [], provider_options: {})
        raise UnsupportedAttachmentError, Array(with).first.mime_type unless Array(with).empty?

        Engine.new(config:, model: model.id, provider_options:).judge(input, questions:, model:)
      end

      def self.assume_models_exist?
        true
      end
    end
  end
end
