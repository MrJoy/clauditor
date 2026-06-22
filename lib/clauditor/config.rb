# frozen_string_literal: true

require "yaml"

module Clauditor
  # Loads optional defaults from a YAML config file (default: ~/.clauditor_config).
  #
  # Every key mirrors a CLI flag, and the returned hash uses the same internal
  # option symbols the CLI assembles, so the CLI can layer it as: built-in
  # defaults < config file < flags actually passed on the command line. A
  # missing file contributes no overrides; an unreadable or malformed file (or
  # an unknown/ill-typed key) raises ArgumentError so the CLI can report it.
  module Config
    DEFAULT_PATH = File.expand_path("~/.clauditor_config")

    def self.load(path: DEFAULT_PATH)
      return {} unless File.exist?(path)

      data =
        begin
          YAML.safe_load_file(path)
        rescue Psych::SyntaxError => e
          raise ArgumentError, "#{path}: invalid YAML (#{e.message})"
        end
      data ||= {} # an empty file parses to nil
      raise ArgumentError, "#{path}: expected a mapping of options" unless data.is_a?(Hash)

      translate(data, path)
    end

    def self.translate(data, path)
      data.each_with_object({}) do |(key, value), options|
        case key.to_s
        when "root", "roots"
          options[:roots] = roots(value, path)
        when "format"
          options[:format] = format(value, path)
        when "utc"
          options[:timezone] = boolean(value, "utc", path) ? :utc : :local
        when "anthropic"
          options[:anthropic] = boolean(value, "anthropic", path)
        when "verbose"
          options[:verbose] = boolean(value, "verbose", path)
        when "project"
          options[:project] = value&.to_s
        when "remap"
          options[:remap] = remap(value, path)
        when "store"
          options[:store] = boolean(value, "store", path)
        when "store_dir"
          options[:store_dir] = File.expand_path(value.to_s)
        else
          raise ArgumentError, "#{path}: unknown option '#{key}'"
        end
      end
    end

    # Accepts either a single path string or a list of them, expanding each.
    def self.roots(value, path)
      list = value.is_a?(Array) ? value : [ value ]
      if list.empty? || list.any? { |dir| !dir.is_a?(String) || dir.strip.empty? }
        raise ArgumentError, "#{path}: 'roots' must be a path or non-empty list of paths"
      end

      list.map { |dir| File.expand_path(dir) }
    end

    # Config-only (no CLI equivalent): a mapping of project path => project
    # path that folds stray project keys — typically long-gone worktrees the
    # repo-root walk can no longer resolve — onto a canonical project. Both
    # sides are expanded so `~` works; the source should be the project path as
    # it appears in the report.
    def self.remap(value, path)
      raise ArgumentError, "#{path}: 'remap' must be a mapping of project => project" unless value.is_a?(Hash)

      value.each_with_object({}) do |(from, to), mapping|
        unless from.is_a?(String) && to.is_a?(String) && !from.strip.empty? && !to.strip.empty?
          raise ArgumentError, "#{path}: 'remap' entries must map a path to a non-empty path"
        end

        mapping[File.expand_path(from)] = File.expand_path(to)
      end
    end

    def self.format(value, path)
      fmt = value.to_s
      return fmt if CLI::FORMATS.include?(fmt)

      raise ArgumentError, "#{path}: invalid format '#{value}' (expected #{CLI::FORMATS.join(", ")})"
    end

    def self.boolean(value, key, path)
      return value if value == true || value == false

      raise ArgumentError, "#{path}: '#{key}' must be true or false"
    end
  end
end
