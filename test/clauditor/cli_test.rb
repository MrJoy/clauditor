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
    # config_path likewise points at a nonexistent file by default so tests
    # never pick up the developer's real ~/.clauditor_config; config tests pass
    # their own path.
    def run_cli(args, store: false, config_path: File.join(Dir.tmpdir, "clauditor-test-absent-config"))
      args = [ "--no-store", *args ] unless store
      out = StringIO.new
      err = StringIO.new
      status = CLI.run(args, out: out, err: err, config_path: config_path)
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

    def test_version_prints_version_and_exits_zero
      out = StringIO.new
      original = $stdout
      $stdout = out
      status = CLI.run([ "--version" ])
      $stdout = original

      assert_equal 0, status
      assert_includes out.string, "clauditor #{Clauditor::VERSION}"
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

    def test_project_filter_to_single_project_hides_project_column
      with_fixture_root do |root|
        status, out, = run_cli([ "--root", root, "--utc", "--project", "proj" ])

        assert_equal 0, status
        refute_includes out, "Project"
        assert out.lines.first.start_with?("Date"), "Date should lead the header"
      end
    end

    def test_unfiltered_run_keeps_project_column
      with_fixture_root do |root|
        status, out, = run_cli([ "--root", root, "--utc" ])

        assert_equal 0, status
        assert_includes out, "Project"
      end
    end

    def test_project_filter_matching_multiple_projects_keeps_column
      with_fixture_root do |a|
        Dir.mktmpdir do |b|
          File.write(File.join(b, "s.jsonl"), <<~JSONL)
            {"type":"assistant","cwd":"/Users/me/project-two","timestamp":"2026-06-07T12:00:00.000Z","message":{"id":"b1","model":"claude-haiku-4-5","usage":{"input_tokens":50,"output_tokens":5}}}
          JSONL

          # "proj" matches both /Users/me/proj and /Users/me/project-two, so the
          # column stays.
          status, out, = run_cli([ "--root", a, "--root", b, "--utc", "--project", "proj" ])

          assert_equal 0, status
          assert_includes out, "Project"
        end
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

    def test_multiple_root_flags_scan_every_root
      with_fixture_root do |a|
        Dir.mktmpdir do |b|
          File.write(File.join(b, "s.jsonl"), <<~JSONL)
            {"type":"assistant","cwd":"/Users/me/other","timestamp":"2026-06-07T12:00:00.000Z","message":{"id":"b1","model":"claude-haiku-4-5","usage":{"input_tokens":50,"output_tokens":5}}}
          JSONL

          status, out, = run_cli([ "--root", a, "--root", b, "--utc" ])

          assert_equal 0, status
          assert_includes out, "opus-4-8"
          assert_includes out, "haiku-4-5"
        end
      end
    end

    def test_config_roots_used_when_no_root_flag
      with_fixture_root do |root|
        with_config("roots:\n  - #{root}\nutc: true\n") do |config_path|
          status, out, = run_cli([], config_path: config_path)

          assert_equal 0, status
          assert_includes out, "opus-4-8"
        end
      end
    end

    def test_cli_root_replaces_config_roots
      with_fixture_root do |cli_root|
        Dir.mktmpdir do |config_root|
          File.write(File.join(config_root, "s.jsonl"), <<~JSONL)
            {"type":"assistant","cwd":"/Users/me/other","timestamp":"2026-06-07T12:00:00.000Z","message":{"id":"c1","model":"claude-haiku-4-5","usage":{"input_tokens":50,"output_tokens":5}}}
          JSONL
          with_config("roots:\n  - #{config_root}\nutc: true\n") do |config_path|
            status, out, = run_cli([ "--root", cli_root ], config_path: config_path)

            assert_equal 0, status
            assert_includes out, "opus-4-8"      # from the CLI root
            refute_includes out, "haiku-4-5"     # config root was replaced, not merged
          end
        end
      end
    end

    def test_flag_overrides_config_non_root_option
      with_fixture_root do |root|
        with_config("format: json\nutc: true\n") do |config_path|
          # Config selects json; absent a --format flag it is honored.
          _status, out, = run_cli([ "--root", root ], config_path: config_path)
          assert_equal 100, JSON.parse(out).first["input_tokens"]

          # An explicit flag wins over the config value.
          _status, out, = run_cli([ "--root", root, "--format", "table" ], config_path: config_path)
          assert_includes out, "TOTAL"
        end
      end
    end

    def test_config_remap_folds_stray_project_onto_canonical
      Dir.mktmpdir do |root|
        File.write(File.join(root, "s.jsonl"), <<~JSONL)
          {"type":"assistant","cwd":"/private/tmp/pr1887-rereview3","timestamp":"2026-06-07T12:00:00.000Z","message":{"id":"m1","model":"claude-opus-4-8","usage":{"input_tokens":100,"output_tokens":10}}}
        JSONL
        with_config("remap:\n  /private/tmp/pr1887-rereview3: /Users/me/Unity/3DTDF2P\nutc: true\n") do |config_path|
          status, out, = run_cli([ "--root", root ], config_path: config_path)

          assert_equal 0, status
          assert_includes out, "/Users/me/Unity/3DTDF2P"
          refute_includes out, "pr1887-rereview3"
        end
      end
    end

    def test_malformed_config_reports_error_and_nonzero_status
      with_config("format: nope\n") do |config_path|
        status, _out, err = run_cli([], config_path: config_path)

        assert_equal 1, status
        assert_includes err, "clauditor:"
      end
    end

    def with_config(body)
      Dir.mktmpdir do |dir|
        path = File.join(dir, "clauditor_config")
        File.write(path, body)
        yield path
      end
    end
  end
end
