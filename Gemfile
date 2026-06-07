# frozen_string_literal: true

source "https://rubygems.org", cooldown: 7

ruby file: ".ruby-version"

# rubocop:disable Bundler/GemVersion
gem "rake"
# rubocop:enable Bundler/GemVersion

# Removed from Ruby 3.4 default gems; required by lib/tasks/github_export.rake.
gem "csv", "~> 3.3"

group :development do
  # rubocop:disable Bundler/GemVersion

  # Audits gems for known security defects (use config/bundler-audit.yml to ignore issues)
  gem "bundler-audit", require: false
  # gem "bundler-leak",                 require: false

  # gem "license_finder",               require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false
  # gem "rubocop",                      require: false
  # gem "rubocop-capybara",             require: false
  # gem "rubocop-eightyfourcodes",      require: false
  # gem "rubocop-graphql",              require: false
  # gem "rubocop-performance",          require: false
  # gem "rubocop-rails",                require: false
  # gem "rubocop-rake",                 require: false
  # gem "rubocop-thread_safety",        require: false
  # gem "rubocop-i18n",                 require: false
  # gem "rubocop-minitest",             require: false
  # gem "derailed_benchmarks", require: false # https://github.com/schneems/derailed_benchmarks
  # gem "stackprof", require: false

  # TODO: https://medium.com/@kirill_shevch/lint-your-ruby-code-with-overcommit-and-static-analysis-tools-bd36d3147d2e

  # gem "rails-erd"

  # rubocop:enable Bundler/GemVersion
end

group :development, :test do
  # rubocop:disable Bundler/GemVersion
  gem "pry"
  # rubocop:enable Bundler/GemVersion
end

group :test do
  gem "simplecov", "~> 0.22.0", require: false
end
