# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "stringio"

module Clauditor
  class CLITest < Minitest::Test
    def with_fixture_root
      Dir.mktmpdir do |root|
        File.write(File.join(root, "s.jsonl"), <<~JSONL)
          {"type":"assistant","cwd":"/Users/me/proj","timestamp":"2026-06-07T12:00:00.000Z","message":{"id":"m1","model":"claude-opus-4-8","usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}}}}
          {"type":"assistant","cwd":"/Users/me/proj","timestamp":"2026-06-07T12:00:00.000Z","message":{"id":"m1","model":"claude-opus-4-8","usage":{"input_tokens":100,"output_tokens":10}}}
        JSONL
        yield root
      end
    end

    # The persistent store is disabled by default so tests never touch the
    # real ~/.clauditor; store-specific tests opt in with their own --store-dir.
    def run_cli(args, store: false)
      args = [ "--no-store", *args ] unless store
      out = StringIO.new
      err = StringIO.new
      status = CLI.run(args, out: out, err: err)
      [ status, out.string, err.string ]
    end

    def test_table_run_dedupes_and_reports
      with_fixture_root do |root|
        status, out, = run_cli([ "--root", root, "--utc" ])

        assert_equal 0, status
        # The duplicated message id must be counted once: 100 input, not 200.
        assert_includes out, "100"
        assert_includes out, "opus-4-8"
        assert_includes out, "TOTAL"
      end
    end

    def test_json_format_emits_parseable_payload
      with_fixture_root do |root|
        status, out, = run_cli([ "--root", root, "--format", "json", "--utc" ])
        payload = JSON.parse(out)

        assert_equal 0, status
        assert_equal 1, payload.size
        assert_equal 100, payload.first["input_tokens"]
      end
    end

    def test_help_prints_usage_and_exits_zero
      _status, _out, _err = nil
      out = StringIO.new
      # --help prints via Kernel#puts to $stdout, so capture it.
      original = $stdout
      $stdout = out
      status = CLI.run([ "--help" ])
      $stdout = original

      assert_equal 0, status
      assert_includes out.string, "Usage: clauditor"
    end

    def test_anthropic_table_renders_crosstab_with_spanning_header
      with_fixture_root do |root|
        status, out, = run_cli([ "--root", root, "--anthropic", "--utc" ])

        assert_equal 0, status
        assert_includes out, "opus-4-8"
        assert_includes out, "Tokens"
        assert_includes out, "Cost"
      end
    end

    def test_anthropic_with_json_exits_one_without_loading
      status, _out, err = run_cli([ "--anthropic", "--format", "json" ])

      assert_equal 1, status
      assert_includes err, "--anthropic is not supported with --format json"
    end

    def test_project_filter_matches_substring
      with_fixture_root do |root|
        status, out, = run_cli([ "--root", root, "--utc", "--project", "proj" ])

        assert_equal 0, status
        assert_includes out, "opus-4-8"
      end
    end

    def test_project_filter_excludes_non_matching
      with_fixture_root do |root|
        _status, out, = run_cli([ "--root", root, "--utc", "--project", "nonexistent" ])

        refute_includes out, "opus-4-8"
      end
    end

    def test_store_serves_persisted_days_after_transcripts_disappear
      with_fixture_root do |root|
        Dir.mktmpdir do |store_dir|
          args = [ "--root", root, "--utc", "--store-dir", store_dir ]
          status, out, = run_cli(args, store: true)

          assert_equal 0, status
          assert_includes out, "2026-06-07"

          # The transcript ages out of Claude Code's retention window; the
          # completed day must survive via the store.
          File.delete(File.join(root, "s.jsonl"))
          status, out, = run_cli(args, store: true)

          assert_equal 0, status
          assert_includes out, "2026-06-07"
          assert_includes out, "100"
        end
      end
    end

    def test_store_does_not_persist_the_current_day
      Dir.mktmpdir do |root|
        Dir.mktmpdir do |store_dir|
          now = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.000Z")
          File.write(File.join(root, "s.jsonl"), <<~JSONL)
            {"type":"assistant","cwd":"/Users/me/proj","timestamp":"#{now}","message":{"id":"m1","model":"claude-opus-4-8","usage":{"input_tokens":100,"output_tokens":10}}}
          JSONL

          status, out, = run_cli([ "--root", root, "--utc", "--store-dir", store_dir ], store: true)

          assert_equal 0, status
          # Today's usage is reported live...
          assert_includes out, "opus-4-8"
          # ...but never persisted: it is still accruing.
          store_files = Dir.glob(File.join(store_dir, "*.json"))
          assert_equal 1, store_files.size
          payload = JSON.parse(File.read(store_files.first))
          assert_empty payload["rows"]
        end
      end
    end

    def test_invalid_format_reports_error_and_nonzero_status
      status, _out, err = run_cli([ "--format", "xml" ])

      assert_equal 1, status
      assert_includes err, "clauditor:"
    end
  end
end
