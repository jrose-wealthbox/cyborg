# frozen_string_literal: true

module Cyborg
  module Bootstrap
    module Assets
      ROOT = File.expand_path("../assets", __dir__).freeze
      CONFIG_PATH = File.join(ROOT, "config.example.toml").freeze
      FIXTURE_PATH = File.join(ROOT, "fixture-records.json").freeze

      module_function

      def config_bytes
        File.binread(CONFIG_PATH)
      end

      def fixture_bytes
        File.binread(FIXTURE_PATH)
      end
    end
  end
end
