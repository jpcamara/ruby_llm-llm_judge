source 'https://rubygems.org'

gemspec

# CI picks the RubyLLM under test: a released version, its main branch, or a local checkout.
if ENV['RUBY_LLM_PATH']
  gem 'ruby_llm', path: ENV['RUBY_LLM_PATH']
elsif ENV['RUBY_LLM_VERSION'] == 'main'
  gem 'ruby_llm', git: 'https://github.com/crmne/ruby_llm.git', branch: 'main'
elsif ENV['RUBY_LLM_VERSION']
  gem 'ruby_llm', ENV['RUBY_LLM_VERSION']
end

gem 'minitest', '~> 5.25'
gem 'rake', '~> 13.0'
gem 'webmock', '~> 3.25'
