# frozen_string_literal: true

require "test_helper"
require "tmpdir"

module Clauditor
  class StoreTest < Minitest::Test
    NOW = Time.utc(2026, 6, 9, 12, 0, 0)

    def build(dir)
      Store.new(root: "/sessions", timezone: :utc, dir: dir, now: NOW)
    end

    def row(project: "/Users/me/proj", date: "2026-06-07", model: "opus-4-8")
      Aggregator::Row.new(
        project: project,
        date: date,
        model: model,
        usage: Usage.new(input: 100, output: 10, cache_read: 5, cache_write_5m: 3, cache_write_1h: 2),
        cost: 1.23,
      )
    end

    def cells(store)
      [].tap { |acc| store.each_row { |*cell| acc << cell } }
    end

    def test_fresh_store_has_no_coverage
      Dir.mktmpdir do |dir|
        store = build(dir)

        assert_nil store.complete_through
        assert_nil store.cutoff_time
        assert_empty cells(store)
      end
    end

    def test_save_and_reload_roundtrips_completed_days
      Dir.mktmpdir do |dir|
        build(dir).save([ row ])
        store = build(dir)

        assert_equal "2026-06-08", store.complete_through
        assert_equal Time.utc(2026, 6, 9), store.cutoff_time

        project, date, model, usage = cells(store).first
        assert_equal "/Users/me/proj", project
        assert_equal "2026-06-07", date
        assert_equal "opus-4-8", model
        assert_equal 100, usage.input
        assert_equal 10, usage.output
        assert_equal 5, usage.cache_read
        assert_equal 3, usage.cache_write_5m
        assert_equal 2, usage.cache_write_1h
      end
    end

    def test_save_excludes_today_and_unknown_dates
      Dir.mktmpdir do |dir|
        build(dir).save([
          row(date: "2026-06-08"),
          row(date: "2026-06-09"), # today, still accruing
          row(date: "unknown"),
        ])
        store = build(dir)

        assert_equal [ "2026-06-08" ], cells(store).map { |cell| cell[1] }
      end
    end

    def test_save_replaces_partial_days_wholesale
      Dir.mktmpdir do |dir|
        build(dir).save([ row ])
        # A later run re-saves the same day with more usage merged in; the
        # dataset must reflect the rewrite, not double the original.
        build(dir).save([ row(date: "2026-06-07"), row(date: "2026-06-08") ])
        store = build(dir)

        dates = cells(store).map { |cell| cell[1] }
        assert_equal %w[2026-06-07 2026-06-08], dates.sort
      end
    end

    def test_unreadable_file_is_treated_as_empty
      Dir.mktmpdir do |dir|
        store = build(dir)
        File.write(store.path, "not json{")

        reloaded = build(dir)
        assert_nil reloaded.complete_through
        assert_empty cells(reloaded)
      end
    end

    def test_mismatched_version_or_roots_is_treated_as_empty
      Dir.mktmpdir do |dir|
        path = build(dir).path
        payload = {
          version: Store::VERSION + 1,
          roots: [ "/sessions" ],
          timezone: "utc",
          complete_through: "2026-06-08",
          rows: [],
        }
        File.write(path, JSON.generate(payload))
        assert_nil build(dir).complete_through

        File.write(path, JSON.generate(payload.merge(version: Store::VERSION, roots: [ "/elsewhere" ])))
        assert_nil build(dir).complete_through
      end
    end

    def test_store_files_are_keyed_by_roots_and_timezone
      Dir.mktmpdir do |dir|
        utc = Store.new(roots: [ "/sessions" ], timezone: :utc, dir: dir, now: NOW)
        local = Store.new(roots: [ "/sessions" ], timezone: :local, dir: dir, now: NOW)
        other = Store.new(roots: [ "/other" ], timezone: :utc, dir: dir, now: NOW)
        many = Store.new(roots: [ "/sessions", "/other" ], timezone: :utc, dir: dir, now: NOW)

        assert_equal 4, [ utc.path, local.path, other.path, many.path ].uniq.size
      end
    end

    def test_root_set_key_ignores_order_and_duplicates
      Dir.mktmpdir do |dir|
        canonical = Store.new(roots: [ "/a", "/b" ], timezone: :utc, dir: dir, now: NOW)
        shuffled = Store.new(roots: [ "/b", "/a", "/a" ], timezone: :utc, dir: dir, now: NOW)

        assert_equal canonical.path, shuffled.path
      end
    end

    def test_single_root_roundtrips_across_roots_and_root_aliases
      Dir.mktmpdir do |dir|
        Store.new(roots: [ "/sessions" ], timezone: :utc, dir: dir, now: NOW).save([ row ])
        store = Store.new(root: "/sessions", timezone: :utc, dir: dir, now: NOW)

        assert_equal "2026-06-08", store.complete_through
        assert_equal "2026-06-07", cells(store).first[1]
      end
    end
  end
end
