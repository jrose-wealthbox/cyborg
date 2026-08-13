# frozen_string_literal: true

require "pathname"

module Cyborg
  module Paths
    Resolved = Data.define(:config, :state, :database, :artifacts, :logs, :lock)

    class Resolved
      alias config_path config
      alias state_dir state
      alias artifact artifacts
      alias log logs
      alias lock_path lock
      alias database_path database
      alias artifact_path artifacts
      alias log_path logs
    end

    module_function

    def resolve(config:, env: ENV)
      environment = (env || {}).each_with_object({}) { |(key, value), result| result[key.to_s] = value.to_s }
      config_paths = config.respond_to?(:paths) ? config.paths : {}
      state_override = environment["CYBORG_STATE_DIR"] || environment["CYBORG_STATE"]
      state = state_override || config_paths["state_dir"]
      state ||= File.join(environment.fetch("HOME", Dir.home), "Library", "Application Support", "CYBORG")
      state = expand(state)

      config_path = config.respond_to?(:path) ? config.path : nil
      database = environment["CYBORG_DATABASE"] || (state_override ? nil : config_paths["database"]) || File.join(state, "cyborg.sqlite3")
      artifacts = environment["CYBORG_ARTIFACT_DIR"] || (state_override ? nil : config_paths["artifacts"]) || File.join(state, "artifacts")
      logs = environment["CYBORG_LOG_DIR"] || (state_override ? nil : config_paths["logs"]) || File.join(state, "logs")
      lock = environment["CYBORG_LOCK_FILE"] || (state_override ? nil : config_paths["lock"]) || File.join(state, "state.lock")
      Resolved.new(config_path && expand(config_path), state, expand(database, state), expand(artifacts, state), expand(logs, state), expand(lock, state))
    end

    def expand(path, base = nil)
      pathname = Pathname.new(path.to_s)
      return pathname.expand_path if pathname.absolute? || base.nil?

      (Pathname.new(base.to_s) / pathname).expand_path
    end
    private_class_method :expand
  end
end
