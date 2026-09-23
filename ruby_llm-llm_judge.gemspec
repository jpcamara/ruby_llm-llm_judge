# frozen_string_literal: true

require_relative 'lib/ruby_llm/llm_judge/version'

Gem::Specification.new do |spec|
  spec.name = 'ruby_llm-llm_judge'
  spec.version = RubyLLM::LLMJudge::VERSION
  spec.summary = 'Use RubyLLM chat models to answer RubyLLM Judge questions'
  spec.authors = ['JP Camara']
  spec.license = 'MIT'
  spec.homepage = 'https://github.com/jpcamara/ruby_llm-llm_judge'
  spec.metadata['source_uri'] = spec.homepage
  spec.metadata['issues_uri'] = "#{spec.homepage}/issues"
  spec.required_ruby_version = '>= 3.1.3'
  spec.files = Dir['lib/**/*.rb', 'README.md', 'LICENSE']
  spec.require_paths = ['lib']
  spec.add_dependency 'ruby_llm', '>= 2.1.0', '< 3.0'
end
