# frozen_string_literal: true

require_relative 'lib/ruby_llm/llm_judge/version'

Gem::Specification.new do |spec|
  spec.name = 'ruby_llm-llm_judge'
  spec.version = RubyLLM::LLMJudge::VERSION
  spec.summary = 'Use RubyLLM chat models to answer RubyLLM Judge questions'
  spec.description = 'Answers probability, choice, and score questions with any RubyLLM chat model, ' \
                     'using parallel per-answer ratings or one-call typed distributions. Plugs into ' \
                     "RubyLLM 2.1's Judge API and also runs on RubyLLM 1.13 through 1.16."
  spec.authors = ['JP Camara']
  spec.license = 'MIT'
  spec.homepage = 'https://github.com/jpcamara/ruby_llm-llm_judge'
  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['changelog_uri'] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata['bug_tracker_uri'] = "#{spec.homepage}/issues"
  spec.metadata['rubygems_mfa_required'] = 'true'
  spec.required_ruby_version = '>= 3.1.3'
  spec.files = Dir['lib/**/*.rb', 'README.md', 'CHANGELOG.md', 'LICENSE']
  spec.require_paths = ['lib']
  spec.add_dependency 'ruby_llm', '>= 1.13.0', '< 3.0'
end
