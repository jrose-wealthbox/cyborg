# frozen_string_literal: true

module Cyborg
  module Commands
    class ConfigPath < Base
      def call(argv)
        parse_options(argv)
        stdout.puts container.config.path.to_s
        0
      end
    end
  end
end
