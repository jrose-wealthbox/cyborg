# frozen_string_literal: true

module Cyborg
  module Commands
    class Actions < Base
      OPERATIONS = Cyborg::Actions::StateMachine::TRANSITIONS.keys.freeze

      def call(argv)
        operation = argv.shift
        raise UsageError.new("cli.missing_action") if operation.nil?
        raise UsageError.new("cli.unknown_action") unless OPERATIONS.include?(operation)

        action_id = argv.shift
        if action_id.nil? || action_id.empty? || action_id.start_with?("--")
          raise UsageError.new("cli.missing_action_id")
        end
        options = parse_options(
          argv,
          optional: %w[origin until]
        )
        action = Cyborg::Actions::StateMachine.new(db:, clock: container.clock).transition(
          action_id:, command: operation, until_time: options["until"], origin: options.fetch("origin", "cli")
        )
        stdout.puts safe_json("action" => normalize(action), "status" => action.user_state)
        0
      end
    end
  end
end
