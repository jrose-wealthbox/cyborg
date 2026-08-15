# frozen_string_literal: true

module Cyborg
  module Commands
    class Init
      def initialize(stdout:, env:, initializer: Bootstrap::Initializer.new)
        @stdout = stdout
        @env = env
        @initializer = initializer
      end

      def call(config_path: nil)
        result = @initializer.call(config_path:, env: @env)
        @stdout.puts(JSON.generate(
          "status" => result.status,
          "config_path" => result.config_path,
          "fixture_path" => result.fixture_path,
          "state_dir" => result.state_dir,
          "database_path" => result.database_path,
          "created" => result.created
        ))
        0
      end
    end
  end
end
