# frozen_string_literal: true

module Cyborg
  module Bootstrap
    Result = Data.define(:status, :config_path, :fixture_path, :state_dir, :database_path, :created)

    class Initializer
      def initialize(filesystem: SafeFilesystem.new, database: Database, assets: Assets)
        @filesystem = filesystem
        @database = database
        @assets = assets
      end

      def call(config_path: nil, env: ENV)
        environment = (env || {}).each_with_object({}) { |(key, value), result| result[key.to_s] = value.to_s }
        created = []
        db = nil

        resolved_config = Config.path(path: config_path, env: environment)
        @filesystem.ensure_directory(path: File.dirname(resolved_config))
        created << "config" if @filesystem.install(path: resolved_config, bytes: @assets.config_bytes) == :created
        config = Config.load(path: resolved_config, env: environment)
        fixture_path = resolve_bootstrap_fixture(config, environment)
        if fixture_path
          @filesystem.ensure_directory(path: File.dirname(fixture_path))
          created << "fixture" if @filesystem.install(path: fixture_path, bytes: @assets.fixture_bytes) == :created
        end

        paths = Paths.resolve(config:, env: environment)
        @filesystem.ensure_directory(path: paths.state.to_s)
        database_state = @filesystem.install(path: paths.database.to_s, bytes: "", mode: 0o600)
        db = @database.connect(path: paths.database)
        db.migrate!
        created << "database" if database_state == :created
        Result.new(created.empty? ? "ready" : "initialized", resolved_config, fixture_path,
          paths.state.to_s, paths.database.to_s, created.freeze)
      ensure
        db&.disconnect
      end

      private

      def resolve_bootstrap_fixture(config, environment)
        source_name, source = config.sources.find { |_name, value| value.enabled && value.adapter == "fixture" }
        return nil unless source

        options = config.source_options(source_name)
        raw_path = options["path"] || options["fixture_path"]
        unless raw_path.is_a?(String) && !raw_path.empty?
          raise InvalidConfiguration.new("config.invalid_fixture_path")
        end

        home = environment.fetch("HOME", Dir.home)
        resolved = if raw_path.start_with?("~/")
          File.expand_path(raw_path.delete_prefix("~/"), home)
        elsif raw_path.start_with?("/")
          File.expand_path(raw_path)
        else
          raise InvalidConfiguration.new("config.invalid_fixture_path")
        end
        unless File.basename(resolved) == "fixture-records.json"
          raise InvalidConfiguration.new("config.invalid_fixture_path")
        end

        default_path = File.expand_path(".config/cyborg/fixture-records.json", home)
        if resolved == default_path
          return resolved unless File.exist?(resolved)
          return resolved if File.file?(resolved)
        elsif File.file?(resolved)
          return resolved
        end

        raise InvalidConfiguration.new("config.invalid_fixture_path")
      end
    end
  end
end
