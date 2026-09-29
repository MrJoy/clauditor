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

    def test_root_accepts_claude_config_dirs
      with_fixture_root do |transcripts|
        Dir.mktmpdir do |claude_dir|
          FileUtils.mkdir_p(File.join(claude_dir, "projects"))
          FileUtils.cp(File.join(transcripts, "s.jsonl"), File.join(claude_dir, "projects", "s.jsonl"))
          # Sits outside projects/ and must not be scanned.
          File.write(File.join(claude_dir, "history.jsonl"), <<~JSONL)
            {"type":"assistant","cwd":"/Users/me/stray","timestamp":"2026-06-07T12:00:00.000Z","message":{"id":"h1","model":"claude-haiku-4-5","usage":{"input_tokens":1,"output_tokens":1}}}
          JSONL

          status, out, = run_cli([ "--root", claude_dir, "--utc" ])

          assert_equal 0, status
          assert_includes out, "proj"
          refute_includes out, "stray"
        end
      end
    end

    def test_project_filter_excludes_non_matching
      with_fixture_root do |root|
        _status, out, = run_cli([ "--root", root, "--utc", "--project", "nonexistent" ])

        refute_includes out, "opus-4-8"
      end
    end

    def test_model_filter_matches_exactly_and_elides_model_column
      with_fixture_root do |root|
        status, out, = run_cli([ "--root", root, "--utc", "--model", "opus-4-8" ])

        assert_equal 0, status
        assert_includes out, "100" # opus row survives
        refute_includes out.lines.first, "Model" # single model → column elided
      end
    end

    def test_model_filter_without_star_does_not_prefix_match
      with_fixture_root do |root|
        _status, out, = run_cli([ "--root", root, "--utc", "--model", "opus" ])

        refute_includes out, "100" # the opus-4-8 row's input tokens
      end
    end

    def test_model_filter_trailing_star_prefix_matches
      with_fixture_root do |root|
        status, out, = run_cli([ "--root", root, "--utc", "--model", "opus*" ])

        assert_equal 0, status
        assert_includes out, "100"
        refute_includes out.lines.first, "Model"
      end
    end

    def test_model_filter_case_insensitive
      with_fixture_root do |root|
        status, out, = run_cli([ "--root", root, "--utc", "--model", "OPUS-4-8" ])

        assert_equal 0, status
        assert_includes out, "100"
        refute_includes out.lines.first, "Model"
      end
    end

    def test_model_filter_excludes_non_matching
      with_fixture_root do |root|
        _status, out, = run_cli([ "--root", root, "--utc", "--model", "haiku*" ])

        refute_includes out, "100" # the opus-4-8 row's input tokens
      end
    end

    def test_model_filter_distinguishes_exact_from_star_across_versions
      Dir.mktmpdir do |root|
        File.write(File.join(root, "s.jsonl"), <<~JSONL)
          {"type":"assistant","cwd":"/Users/me/proj","timestamp":"2026-06-07T12:00:00.000Z","message":{"id":"a1","model":"claude-opus-5","usage":{"input_tokens":100,"output_tokens":10}}}
          {"type":"assistant","cwd":"/Users/me/proj","timestamp":"2026-06-07T12:00:00.000Z","message":{"id":"a2","model":"claude-opus-5-5","usage":{"input_tokens":50,"output_tokens":5}}}
        JSONL

        _status, exact, = run_cli([ "--root", root, "--utc", "--model", "opus-5" ])
        _status, starred, = run_cli([ "--root", root, "--utc", "--model", "opus-5*" ])

        # Exact: only opus-5 survives, so the Model column is elided.
        refute_includes exact.lines.first, "Model"
        refute_includes exact, "opus-5-5"
        # Starred: both versions survive and the Model column stays.
        assert_includes starred.lines.first, "Model"
        assert_includes starred, "opus-5-5"
        assert_match(/opus-5\s/, starred)
      end
    end

    def test_model_filter_matching_multiple_models_keeps_column
      with_fixture_root do |a|
        Dir.mktmpdir do |b|
          File.write(File.join(b, "s.jsonl"), <<~JSONL)
            {"type":"assistant","cwd":"/Users/me/proj","timestamp":"2026-06-07T12:00:00.000Z","message":{"id":"b1","model":"claude-haiku-4-5","usage":{"input_tokens":50,"output_tokens":5}}}
          JSONL

          # No --model given: both opus and haiku are present, so the Model column
          # stays.
          status, out, = run_cli([ "--root", a, "--root", b, "--utc" ])

          assert_equal 0, status
          assert_includes out.lines.first, "Model"
          assert_includes out, "opus-4-8"
          assert_includes out, "haiku-4-5"
        end
      end
    end

    def test_model_filter_from_config_default
      Dir.mktmpdir do |dir|
        config = File.join(dir, "cfg.yml")
        File.write(config, "model: opus*\n")
        with_fixture_root do |root|
          status, out, = run_cli([ "--root", root, "--utc" ], config_path: config)

          assert_equal 0, status
          assert_includes out, "100"
          refute_includes out.lines.first, "Model"
        end
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

    def test_changing_roots_keeps_each_roots_persisted_history
      with_fixture_root do |a|
        Dir.mktmpdir do |b|
          Dir.mktmpdir do |store_dir|
            File.write(File.join(b, "s.jsonl"), <<~JSONL)
              {"type":"assistant","cwd":"/Users/me/other","timestamp":"2026-06-08T12:00:00.000Z","message":{"id":"b1","model":"claude-haiku-4-5","usage":{"input_tokens":50,"output_tokens":5}}}
            JSONL
            store = [ "--utc", "--store-dir", store_dir ]

            run_cli([ "--root", a, *store ], store: true)
            # a's transcript ages out; only the store remembers 2026-06-07.
            File.delete(File.join(a, "s.jsonl"))

            _status, both, = run_cli([ "--root", a, "--root", b, *store ], store: true)
            _status, b_only, = run_cli([ "--root", b, *store ], store: true)
            _status, a_again, = run_cli([ "--root", a, *store ], store: true)

            assert_includes both, "2026-06-07"
            assert_includes both, "2026-06-08"
            refute_includes b_only, "2026-06-07"
            assert_includes a_again, "2026-06-07"
            assert_includes a_again, "100"
          end
        end
      end
    end

    def test_nested_roots_are_not_counted_twice_across_stores
      with_fixture_root do |root|
        Dir.mktmpdir do |store_dir|
          nested = File.join(root, "nested")
          FileUtils.mkdir_p(nested)
          FileUtils.mv(File.join(root, "s.jsonl"), File.join(nested, "s.jsonl"))
          args = [ "--root", root, "--root", nested, "--utc", "--format", "json", "--store-dir", store_dir ]

          run_cli(args, store: true)
          _status, out, = run_cli(args, store: true)

          assert_equal [ 100 ], JSON.parse(out).map { |row| row["input_tokens"] }
          assert_equal 1, Dir.glob(File.join(store_dir, "*.json")).size
        end
      end
    end

    def write_archive(store_dir, roots, rows, name: "archive", complete_through: "2026-06-08")
      path = File.join(store_dir, "usage-utc-#{name}.json")
      File.write(path, JSON.generate(version: Store::VERSION, roots: roots, timezone: "utc", complete_through: complete_through, rows: rows))
      path
    end

    def archive_row(date, input, project: "/Users/me/proj")
      { project: project, date: date, model: "opus-4-8", input: input, output: 0 }
    end

    def input_by_date(out)
      JSON.parse(out).to_h { |row| [ row["date"], row["input_tokens"] ] }
    end

    def test_root_set_archive_reconciles_with_its_roots_by_per_cell_max
      with_fixture_root do |a|
        Dir.mktmpdir do |b|
          Dir.mktmpdir do |store_dir|
            # A 0.0.3 dataset for {a, b}: 2026-05-01 predates every transcript,
            # and 2026-06-07 repeats a's fixture day plus b's usage.
            archive = write_archive(store_dir, [ a, b ], [ archive_row("2026-05-01", 7), archive_row("2026-06-07", 150) ])
            args = [ "--root", a, "--root", b, "--utc", "--format", "json", "--store-dir", store_dir ]

            _status, first, = run_cli(args, store: true)
            _status, second, = run_cli(args, store: true)

            expected = { "2026-05-01" => 7, "2026-06-07" => 150 }
            assert_equal expected, input_by_date(first)
            assert_equal expected, input_by_date(second)
            assert_equal 2, JSON.parse(File.read(archive))["rows"].size

            # Alone, a can't use the {a, b} archive, but its own store kept 06-07.
            _status, a_only, = run_cli([ "--root", a, "--utc", "--format", "json", "--store-dir", store_dir ], store: true)
            assert_equal({ "2026-06-07" => 100 }, input_by_date(a_only))
          end
        end
      end
    end

    def test_most_recent_archive_wins_when_archives_share_a_root
      with_fixture_root do |a|
        Dir.mktmpdir do |b|
          Dir.mktmpdir do |store_dir|
            File.delete(File.join(a, "s.jsonl"))
            write_archive(store_dir, [ a, b ], [ archive_row("2026-05-01", 1) ], name: "older", complete_through: "2026-05-31")
            write_archive(store_dir, [ a, b ], [ archive_row("2026-05-01", 2) ], name: "newer", complete_through: "2026-06-08")

            _status, out, = run_cli([ "--root", a, "--root", b, "--utc", "--format", "json", "--store-dir", store_dir ], store: true)

            assert_equal({ "2026-05-01" => 2 }, input_by_date(out))
          end
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

    def test_rollup_table_collapses_dates
      Dir.mktmpdir do |root|
        File.write(File.join(root, "s.jsonl"), <<~JSONL)
          {"type":"assistant","cwd":"/Users/me/proj","timestamp":"2026-06-07T12:00:00.000Z","message":{"id":"m1","model":"claude-opus-4-8","usage":{"input_tokens":100,"output_tokens":10}}}
          {"type":"assistant","cwd":"/Users/me/proj","timestamp":"2026-06-08T12:00:00.000Z","message":{"id":"m2","model":"claude-opus-4-8","usage":{"input_tokens":50,"output_tokens":5}}}
        JSONL
        status, out, = run_cli([ "--root", root, "--utc", "--rollup" ])

        assert_equal 0, status
        assert_includes out, "Model"
        refute_includes out, "Date"
        assert_includes out, "150"
        data = out.lines.select { |l| l.include?("opus-4-8") }
        assert_equal 1, data.size
      end
    end

    def test_rollup_table_abbreviates_tokens_unless_verbose
      Dir.mktmpdir do |root|
        File.write(File.join(root, "s.jsonl"), <<~JSONL)
          {"type":"assistant","cwd":"/Users/me/proj","timestamp":"2026-06-07T12:00:00.000Z","message":{"id":"m1","model":"claude-opus-4-8","usage":{"input_tokens":1999980,"output_tokens":10}}}
        JSONL

        _status, out, = run_cli([ "--root", root, "--utc", "--rollup" ])
        assert_includes out, "2.0m"
        refute_includes out, "1,999,980"

        _status, vout, = run_cli([ "--root", root, "--utc", "--rollup", "--verbose" ])
        assert_includes vout, "1,999,980"
        refute_includes vout, "2.0m"
      end
    end

    def test_rollup_json_collapses_dates
      Dir.mktmpdir do |root|
        File.write(File.join(root, "s.jsonl"), <<~JSONL)
          {"type":"assistant","cwd":"/Users/me/proj","timestamp":"2026-06-07T12:00:00.000Z","message":{"id":"m1","model":"claude-opus-4-8","usage":{"input_tokens":100,"output_tokens":10}}}
          {"type":"assistant","cwd":"/Users/me/proj","timestamp":"2026-06-08T12:00:00.000Z","message":{"id":"m2","model":"claude-opus-4-8","usage":{"input_tokens":50,"output_tokens":5}}}
        JSONL
        status, out, = run_cli([ "--root", root, "--utc", "--rollup", "--format", "json" ])
        payload = JSON.parse(out)

        assert_equal 0, status
        assert_equal 1, payload.size
        assert_equal 150, payload.first["input_tokens"]
        refute payload.first.key?("date")
      end
    end

    def test_rollup_days_window_excludes_older_rows
      Dir.mktmpdir do |root|
        recent = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.000Z")
        File.write(File.join(root, "s.jsonl"), <<~JSONL)
          {"type":"assistant","cwd":"/Users/me/proj","timestamp":"2000-01-01T12:00:00.000Z","message":{"id":"old","model":"claude-opus-4-8","usage":{"input_tokens":999,"output_tokens":1}}}
          {"type":"assistant","cwd":"/Users/me/proj","timestamp":"#{recent}","message":{"id":"new","model":"claude-opus-4-8","usage":{"input_tokens":42,"output_tokens":1}}}
        JSONL
        status, out, = run_cli([ "--root", root, "--utc", "--rollup", "--days", "1" ])

        assert_equal 0, status
        assert_includes out, "42"
        refute_includes out, "999"
      end
    end

    def test_rollup_since_window_excludes_older_rows
      Dir.mktmpdir do |root|
        File.write(File.join(root, "s.jsonl"), <<~JSONL)
          {"type":"assistant","cwd":"/Users/me/proj","timestamp":"2026-06-01T12:00:00.000Z","message":{"id":"a","model":"claude-opus-4-8","usage":{"input_tokens":11,"output_tokens":1}}}
          {"type":"assistant","cwd":"/Users/me/proj","timestamp":"2026-06-10T12:00:00.000Z","message":{"id":"b","model":"claude-opus-4-8","usage":{"input_tokens":22,"output_tokens":1}}}
        JSONL
        status, out, = run_cli([ "--root", root, "--utc", "--rollup", "--since", "2026-06-05" ])

        assert_equal 0, status
        assert_includes out, "22"
        refute_includes out, "11"
      end
    end

    def test_rollup_with_anthropic_errors
      status, _out, err = run_cli([ "--rollup", "--anthropic" ])

      assert_equal 1, status
      assert_includes err, "--rollup and --anthropic cannot be combined"
    end

    def test_days_and_since_together_error
      status, _out, err = run_cli([ "--rollup", "--days", "7", "--since", "2026-06-01" ])

      assert_equal 1, status
      assert_includes err, "--days and --since cannot be combined"
    end

    def test_days_without_rollup_errors
      status, _out, err = run_cli([ "--days", "7" ])

      assert_equal 1, status
      assert_includes err, "--days requires --rollup"
    end

    def test_since_without_rollup_errors
      status, _out, err = run_cli([ "--since", "2026-06-01" ])

      assert_equal 1, status
      assert_includes err, "--since requires --rollup"
    end

    def test_days_non_positive_errors
      status, _out, err = run_cli([ "--rollup", "--days", "0" ])

      assert_equal 1, status
      assert_includes err, "--days must be a positive integer"
    end

    def test_invalid_since_date_errors
      status, _out, err = run_cli([ "--rollup", "--since", "nope" ])

      assert_equal 1, status
      assert_includes err, "invalid --since date"
    end

    def test_rollup_single_project_hides_project_column
      Dir.mktmpdir do |root|
        File.write(File.join(root, "s.jsonl"), <<~JSONL)
          {"type":"assistant","cwd":"/Users/me/proj","timestamp":"2026-06-07T12:00:00.000Z","message":{"id":"m1","model":"claude-opus-4-8","usage":{"input_tokens":100,"output_tokens":10}}}
        JSONL
        status, out, = run_cli([ "--root", root, "--utc", "--rollup", "--project", "proj" ])

        assert_equal 0, status
        refute_includes out, "Project"
        assert out.lines.first.start_with?("Model"), "Model should lead when project hidden"
      end
    end

    def test_config_days_without_rollup_errors
      with_config("days: 7\n") do |config_path|
        status, _out, err = run_cli([], config_path: config_path)

        assert_equal 1, status
        assert_includes err, "--days requires --rollup"
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
