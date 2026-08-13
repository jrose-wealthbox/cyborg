# frozen_string_literal: true

module Cyborg
  module Commands
    class CacheInvalidate < Base
      COMMANDS = %w[cyborg-no-cache cyborg-no-cache-even-expensive].freeze

      def call(argv)
        options = parse_options(argv, required: %w[classes], optional: %w[command run reason])
        raw_classes = options.fetch("classes")
        classes = if raw_classes == "full"
          %w[ordinary expensive]
        else
          raw_classes.split(",").map(&:strip).reject(&:empty?).uniq
        end
        unless classes.length.positive? && classes.all? { |cache_class| CachePolicy::CACHE_CLASSES.include?(cache_class) }
          raise UsageError.new("cli.invalid_cache_class")
        end
        command = options.fetch("command") { classes.include?("expensive") ? COMMANDS.fetch(1) : COMMANDS.fetch(0) }
        raise UsageError.new("cli.invalid_invalidation_command") unless COMMANDS.include?(command)
        reason = bounded_metadata(options.fetch("reason", "user_requested"))
        run_id = options["run"]
        policy = CachePolicy.new(
          ordinary_ttl_seconds: container.config.cache.ordinary_ttl_seconds,
          expensive_ttl_seconds: container.config.cache.expensive_ttl_seconds
        )
        policy.invalidate(
          repository: Repositories::CacheRepository.new(db), classes:, invalidated_at: container.clock.now.utc.iso8601,
          command:, run_id:, reason:
        )
        stdout.puts safe_json("status" => "invalidated", "classes" => classes.sort, "command" => command)
        0
      end

      private

      def bounded_metadata(value)
        Redactor.new.call(value.to_s).byteslice(0, 256).to_s
      end
    end
  end
end
