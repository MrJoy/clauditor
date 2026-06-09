# frozen_string_literal: true

require "test_helper"
require "tmpdir"

module Clauditor
  class SessionLoaderTest < Minitest::Test
    def test_reads_records_across_nested_files_and_skips_bad_lines
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "proj-a"))
        FileUtils.mkdir_p(File.join(root, "proj-b"))
        File.write(File.join(root, "proj-a", "s1.jsonl"), <<~JSONL)
          {"type":"assistant","message":{"id":"a"}}

          not valid json
          {"type":"user"}
        JSONL
        File.write(File.join(root, "proj-b", "s2.jsonl"), %({"type":"system"}\n))

        records = SessionLoader.new(root: root).each_record.to_a
        types = records.map { |r| r["type"] }

        assert_equal 3, records.size
        assert_equal %w[assistant system user], types.sort
      end
    end

    def test_since_skips_files_last_modified_before_the_cutoff
      Dir.mktmpdir do |root|
        old = File.join(root, "old.jsonl")
        fresh = File.join(root, "fresh.jsonl")
        File.write(old, %({"type":"assistant"}\n))
        File.write(fresh, %({"type":"system"}\n))
        File.utime(Time.now, Time.now - 86_400, old)

        records = SessionLoader.new(root: root, since: Time.now - 3_600).each_record.to_a

        assert_equal [ "system" ], records.map { |r| r["type"] }
      end
    end

    def test_each_record_without_block_returns_enumerator
      Dir.mktmpdir do |root|
        File.write(File.join(root, "s.jsonl"), %({"type":"assistant"}\n))

        assert_kind_of Enumerator, SessionLoader.new(root: root).each_record
      end
    end
  end
end
