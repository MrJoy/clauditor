# frozen_string_literal: true

desc "Run cloc, excluding vendored code, compiled artifacts, etc."
task :cloc do
  # N.B. Each entry here is a Perl regex!
  off_limits_dirs = %w[
    \.bundle
    \.claude
    bin
    coverage
    data
    docs
    log
    tmp
    vendor
  ]

  off_limits_files = %w[
    Gemfile\.lock
    .*\.log
  ]

  sh [
    "cloc",
    ".",
    "--fullpath",
    "--not-match-d='#{off_limits_dirs.join("|")}'",
    "--not-match-f='#{off_limits_files.join("|")}'",
    # "--counted=tmp/counted.txt",
  ].join(" ")
end
