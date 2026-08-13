# frozen_string_literal: true

require "json"

module Cyborg
  class CLI
    def self.start(argv, stdout: $stdout, stderr: $stderr, env: ENV)
      if argv == ["version"]
        stdout.puts(JSON.generate("version" => VERSION))
        return 0
      end

      stderr.puts("cli.unknown_command: #{argv.first.inspect}")
      64
    end
  end
end
