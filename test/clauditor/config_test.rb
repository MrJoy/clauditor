# frozen_string_literal: true

require "test_helper"
require "tmpdir"

module Clauditor
  class ConfigTest < Minitest::Test
    def with_config(body)
      Dir.mktmpdir do |dir|
        path = File.join(dir, "clauditor_config")
        File.write(path, body)
        yield path
      end
    end

    def test_missing_file_yields_no_overrides
      assert_empty Config.load(path: "/no/such/clauditor_config")
    end

    def test_empty_file_yields_no_overrides
      with_config("") { |path| assert_empty Config.load(path: path) }
    end

    def test_translates_every_known_option
      with_config(<<~YAML) do |path|
        roots:
          - ~/one
          - /two
        format: csv
        utc: true
        anthropic: true
        verbose: true
        project: clauditor
        remap:
          /private/tmp/gone: ~/real
        store: false
        store_dir: ~/store
      YAML
        options = Config.load(path: path)

        assert_equal [ File.expand_path("~/one"), "/two" ], options[:roots]
        assert_equal "csv", options[:format]
        assert_equal :utc, options[:timezone]
        assert_equal true, options[:anthropic]
        assert_equal true, options[:verbose]
        assert_equal "clauditor", options[:project]
        assert_equal({ "/private/tmp/gone" => File.expand_path("~/real") }, options[:remap])
        assert_equal false, options[:store]
        assert_equal File.expand_path("~/store"), options[:store_dir]
      end
    end

    def test_remap_expands_both_sides
      with_config(<<~YAML) do |path|
        remap:
          /private/tmp/pr1887-rereview3: ~/Unity/Games/3DTDF2P
          ~/old/checkout: /Users/me/new
      YAML
        remap = Config.load(path: path)[:remap]

        assert_equal File.expand_path("~/Unity/Games/3DTDF2P"), remap["/private/tmp/pr1887-rereview3"]
        assert_equal "/Users/me/new", remap[File.expand_path("~/old/checkout")]
      end
    end

    def test_remap_non_mapping_raises
      with_config("remap: just-a-string\n") do |path|
        error = assert_raises(ArgumentError) { Config.load(path: path) }
        assert_includes error.message, "must be a mapping"
      end
    end

    def test_remap_empty_target_raises
      with_config("remap:\n  /a: \"\"\n") do |path|
        error = assert_raises(ArgumentError) { Config.load(path: path) }
        assert_includes error.message, "non-empty path"
      end
    end

    def test_utc_false_maps_to_local
      with_config("utc: false\n") do |path|
        assert_equal :local, Config.load(path: path)[:timezone]
      end
    end

    def test_singular_root_string_is_accepted
      with_config("root: /solo\n") do |path|
        assert_equal [ "/solo" ], Config.load(path: path)[:roots]
      end
    end

    def test_invalid_format_raises
      with_config("format: xml\n") do |path|
        error = assert_raises(ArgumentError) { Config.load(path: path) }
        assert_includes error.message, "invalid format"
      end
    end

    def test_unknown_key_raises
      with_config("bogus: 1\n") do |path|
        error = assert_raises(ArgumentError) { Config.load(path: path) }
        assert_includes error.message, "unknown option"
      end
    end

    def test_non_mapping_raises
      with_config("- just\n- a\n- list\n") do |path|
        assert_raises(ArgumentError) { Config.load(path: path) }
      end
    end

    def test_non_boolean_flag_raises
      # YAML parses this as a plain string, not a boolean.
      with_config("utc: sometimes\n") do |path|
        error = assert_raises(ArgumentError) { Config.load(path: path) }
        assert_includes error.message, "true or false"
      end
    end

    def test_empty_roots_list_raises
      with_config("roots: []\n") do |path|
        assert_raises(ArgumentError) { Config.load(path: path) }
      end
    end

    def test_malformed_yaml_raises
      with_config("roots: [unterminated\n") do |path|
        error = assert_raises(ArgumentError) { Config.load(path: path) }
        assert_includes error.message, "invalid YAML"
      end
    end
  end
end
