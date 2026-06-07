# frozen_string_literal: true

require "rake/testtask"

FileList["lib/tasks/**/*.rake"].each { |fname| load fname }

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.test_files = FileList["test/**/*_test.rb"]
  t.verbose = true
end
