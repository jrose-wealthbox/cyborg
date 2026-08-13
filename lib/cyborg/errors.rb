# frozen_string_literal: true

module Cyborg
  class Error < StandardError
    DEFAULT_EXIT_STATUS = 70

    attr_reader :code, :exit_status

    def initialize(code, message = nil, exit_status: self.class::DEFAULT_EXIT_STATUS)
      @code = code.to_s
      @exit_status = exit_status
      super(message || @code)
    end
  end

  class UsageError < Error
    DEFAULT_EXIT_STATUS = 64
  end

  # Raised before a host analysis call when deterministic packet limits would
  # otherwise be exceeded.  No source data or analysis claims are persisted.
  class PacketTooLarge < UsageError
    def initialize(message = "analysis packet exceeds configured byte limit")
      super("analysis.packet_too_large", message)
    end
  end

  class InvalidArtifact < Error
    DEFAULT_EXIT_STATUS = 65
  end

  class UnsafeArtifact < InvalidArtifact
    DEFAULT_EXIT_STATUS = 65
  end

  class InternalError < Error
    DEFAULT_EXIT_STATUS = 70
  end

  UnexpectedError = InternalError

  class PersistenceError < Error
    DEFAULT_EXIT_STATUS = 73
  end

  DatabaseError = PersistenceError

  class LeaseBusy < Error
    DEFAULT_EXIT_STATUS = 75
  end

  class ConfigurationError < Error
    DEFAULT_EXIT_STATUS = 78
  end

  # Source adapters use these errors for bounded, machine-readable retrieval
  # failures. They are data failures, not authorization to broaden a request.
  class SourceError < Error
    DEFAULT_EXIT_STATUS = 70
  end

  class SourceLimitError < SourceError
    DEFAULT_EXIT_STATUS = 64
  end

  # Raised when the resolved TOML configuration cannot be safely used.
  # Keep this distinct from a generic configuration failure so callers can
  # report a stable, machine-readable validation code.
  class InvalidConfiguration < ConfigurationError
    DEFAULT_EXIT_STATUS = 78
  end

  ConfigError = ConfigurationError
end
