# frozen_string_literal: true

require "json"
require "fileutils"

module Cyborg
  class CLI
    Container = Data.define(:config, :paths, :db, :clock, :env)
    COMMANDS = {
      "prepare" => Commands::Prepare,
      "ingest" => Commands::Ingest,
      "analysis-packet" => Commands::AnalysisPacket,
      "record-result" => Commands::RecordResult,
      "render" => Commands::Render
    }.freeze

    def self.start(argv, stdout: $stdout, stderr: $stderr, env: ENV)
      new(stdout:, stderr:, env:).dispatch(Array(argv).dup)
    end

    def initialize(stdout:, stderr:, env:)
      @stdout = stdout
      @stderr = stderr
      @env = (env || {}).each_with_object({}) { |(key, value), result| result[key.to_s] = value.to_s }
    end

    def dispatch(argv)
      if argv == ["version"]
        @stdout.puts(JSON.generate("version" => VERSION))
        return 0
      end

      command = argv.shift
      unless COMMANDS.key?(command) || %w[runs actions config cache].include?(command)
        raise UsageError.new("cli.unknown_command")
      end
      config_path = extract_config!(argv)
      container = build_container(config_path)
      begin
        command_class, command_args = case command
        when "runs"
          nested = argv.shift
          raise UsageError.new("cli.unknown_command") unless nested == "abandon"

          [Commands::RunsAbandon, argv]
        when "actions"
          [Commands::Actions, argv]
        when "config"
          nested = argv.shift
          raise UsageError.new("cli.unknown_command") unless nested == "path"

          [Commands::ConfigPath, argv]
        when "cache"
          nested = argv.shift
          raise UsageError.new("cli.unknown_command") unless nested == "invalidate"

          [Commands::CacheInvalidate, argv]
        else
          [COMMANDS.fetch(command), argv]
        end
        command_class.new(container:, stdout: @stdout, stderr: @stderr).call(command_args)
      ensure
        container.db.disconnect
      end
    rescue Cyborg::Error => error
      @stdout.truncate(0) if @stdout.respond_to?(:truncate) && @stdout.respond_to?(:string)
      @stderr.puts(error.code)
      error.exit_status
    rescue Sequel::Error, SQLite3::Exception
      @stderr.puts("database.persistence")
      73
    rescue Errno::EACCES, Errno::EPERM, Errno::ENOSPC
      @stderr.puts("bridge.persistence")
      73
    rescue StandardError
      @stderr.puts("cli.internal_error")
      70
    end

    private

    def extract_config!(argv)
      index = argv.index("--config")
      return nil unless index

      value = argv[index + 1]
      raise UsageError.new("cli.missing_option_value") if value.nil? || value.start_with?("--")

      argv.slice!(index, 2)
      value
    end

    def build_container(config_path)
      config_env = @env.dup
      config_env["CYBORG_CONFIG"] = config_path if config_path
      config = Config.load(path: nil, env: config_env)
      paths = Paths.resolve(config:, env: config_env)
      FileUtils.mkdir_p(paths.state.to_s)
      db = Database.connect(path: paths.database.to_s)
      db.migrate!
      Container.new(config:, paths:, db:, clock: Clock.new, env: config_env.freeze)
    rescue Cyborg::Error
      raise
    rescue Sequel::Error, SQLite3::Exception
      raise DatabaseError.new("database.connect")
    end
  end
end
