# frozen_string_literal: true

namespace :lint do
  desc "Run RuboCop"
  task :rubocop do
    sh "rubocop"
  end

  desc "Run bundler-audit"
  task :bundle_audit do
    sh "bundler-audit"
  end

  # desc "Run bundle-leak"
  # task :bundle_leak do
  #   sh "bundle-leak check --update"
  # end
end

desc "Run all lint tasks"
task lint: %i[
  lint:rubocop
  lint:bundle_audit
]
# lint:bundle_leak
