# frozen_string_literal: true

module Cyborg
  module Commands
    class RunsAbandon < Base
      def call(argv)
        options = parse_options(argv, required: %w[run lease-file], optional: %w[reason])
        run_id = options.fetch("run")
        lease_file = options.fetch("lease-file")
        verify_and_renew!(run_id:, lease_file:)
        lifecycle = Runs::RunLifecycle.new(
          db, clock: container.clock, lease_timeout_seconds: container.config.timeouts.lease_timeout_seconds,
          lease_file:, lock_file: container.paths.lock
        )
        run = lifecycle.abandon(run_id:, reason: options.fetch("reason", "abandoned by host"))
        stdout.puts safe_json("run_id" => run.id, "status" => run.status)
        0
      end
    end
  end
end
