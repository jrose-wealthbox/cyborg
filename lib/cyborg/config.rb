# frozen_string_literal: true

require "date"
require "pathname"
require "toml-rb"
require "tzinfo"

module Cyborg
  # A resolved calendar profile. The values inside this Data object are deeply
  # frozen by Config.load, so a loaded Config can safely be shared by services.
  Profile = Data.define(
    :name, :timezone, :working_hours, :weekend_days, :holidays, :observed,
    :easter, :overrides, :holiday_additions, :holiday_removals,
    :window_before_business_days, :window_after_business_days
  )

  Source = Data.define(
    :name, :adapter, :enabled, :account, :repositories, :channels, :filters,
    :limits, :required
  )

  Budget = Data.define(:ceiling_micros, :required_reservation_micros)
  Cache = Data.define(:ordinary_ttl_seconds, :expensive_ttl_seconds)
  Timeouts = Data.define(:lease_timeout_seconds, :analysis_timeout_seconds)

  # Configuration is deliberately a plain, immutable value. It contains
  # source identifiers and policy only; secrets are rejected during loading.
  class Config
    DEFAULT_CONFIG_PATH = File.join(".config", "cyborg", "config.toml").freeze
    DEFAULT_TIMEZONE = "UTC".freeze
    DEFAULT_LEASE_TIMEOUT_SECONDS = 600
    DEFAULT_ANALYSIS_TIMEOUT_SECONDS = 300
    DEFAULT_CEILING_MICROS = 5_000_000
    DEFAULT_ORDINARY_CACHE_TTL_SECONDS = 1_800
    DEFAULT_EXPENSIVE_CACHE_TTL_SECONDS = 14_400
    DEFAULT_PROFILE_HOLIDAYS = %w[
      new_years_day martin_luther_king_jr_day juneteenth independence_day labor_day
      thanksgiving christmas
    ].freeze
    DEFAULT_WORKING_HOURS = {"start" => "09:00", "end" => "17:00"}.freeze
    WEEKDAY_NAMES = %w[sunday monday tuesday wednesday thursday friday saturday].freeze

    KNOWN_ROOT_SECTIONS = %w[
      analysis budget cache calendar database defaults footer filters llm output
      paths profile profiles renderer repositories required runtime source sources
      tasks timeouts timezone window working_hours
    ].freeze

    SECRET_KEY = /(?:secret|token|password|passwd|credential|authorization|api[_-]?key|access[_-]?key|private[_-]?key)/i
    ENUMS = {
      "execution_mode" => %w[interactive unattended host],
      "mode" => %w[interactive unattended host],
      "adapter" => %w[github local_git git],
      "cache_class" => %w[ordinary expensive]
    }.freeze

    attr_reader :path, :profiles, :sources, :budget, :cache, :timeouts,
      :paths, :runtime, :analysis, :renderer, :output, :footer

    class << self
      def load(path:, env: ENV)
        environment = normalize_env(env)
        resolved_path = resolve_config_path(path, environment)
        unless File.file?(resolved_path)
          raise_invalid("config.not_found", "configuration file does not exist: #{resolved_path}")
        end

        begin
          raw = TomlRB.load_file(resolved_path, symbolize_keys: false)
        rescue StandardError
          raise_invalid("config.invalid_toml", "configuration could not be parsed")
        end
        unless raw.is_a?(Hash)
          raise_invalid("config.invalid_toml", "configuration root must be a TOML table")
        end

        reject_secret_keys!(raw)
        validate_enums!(raw)
        validate_root_sections!(raw)
        new(resolved_path, raw, environment)
      rescue InvalidConfiguration
        raise
      end

      private

      def normalize_env(env)
        (env || {}).each_with_object({}) { |(key, value), result| result[key.to_s] = value.to_s }
      end

      def resolve_config_path(path, env)
        candidate = if path && !path.to_s.empty?
          path.to_s
        elsif env["CYBORG_CONFIG"] && !env["CYBORG_CONFIG"].empty?
          env["CYBORG_CONFIG"]
        else
          File.join(env.fetch("HOME", Dir.home), DEFAULT_CONFIG_PATH)
        end
        Pathname.new(candidate).expand_path.to_s
      end

      def reject_secret_keys!(value)
        case value
        when Hash
          value.each do |key, item|
            if key.to_s.match?(SECRET_KEY)
              raise_invalid("config.secret_forbidden", "secret-shaped configuration keys are not allowed")
            end
            reject_secret_keys!(item)
          end
        when Array
          value.each { |item| reject_secret_keys!(item) }
        end
      end

      def validate_root_sections!(raw)
        unknown = raw.keys.map(&:to_s).reject { |key| KNOWN_ROOT_SECTIONS.include?(key) }
        return if unknown.empty?

        raise_invalid("config.unknown_section", "unknown configuration section")
      end

      def validate_enums!(value)
        case value
        when Hash
          value.each do |key, item|
            allowed = ENUMS[key.to_s]
            if allowed && !allowed.include?(item.to_s)
              raise_invalid("config.invalid_enum", "unsupported enum value")
            end
            validate_enums!(item)
          end
        when Array
          value.each { |item| validate_enums!(item) }
        end
      end

      def raise_invalid(code, message = nil)
        raise InvalidConfiguration.new(code, message)
      end
    end

    def initialize(path, raw, env)
      @path = Pathname.new(path).freeze
      @raw = deep_freeze(stringify_keys(raw))
      @environment = env.dup.freeze

      @runtime = resolve_runtime(@raw, @environment)
      @paths = resolve_paths(@raw, @environment)
      @profiles = resolve_profiles(@raw, @runtime)
      @sources = resolve_sources(@raw)
      @budget = resolve_budget(@raw)
      @cache = resolve_cache(@raw)
      @timeouts = resolve_timeouts(@raw, @runtime)
      @analysis = deep_freeze(fetch_hash(@raw, "analysis"))
      @renderer = deep_freeze(fetch_hash(@raw, "renderer", "output"))
      @output = deep_freeze(fetch_hash(@raw, "output"))
      @footer = @raw["footer"]
      calendar_default = fetch_hash(@raw, "calendar")["default_profile"]
      @profile_name = (@environment["CYBORG_PROFILE"] || @runtime["profile"] || @runtime["calendar_profile"] || calendar_default || "default").to_s
      unless @profiles.key?(@profile_name)
        raise_invalid("config.unknown_profile", "unknown calendar profile")
      end
      validate_required_sections!
      validate_required_paths!
      validate_timeout_consistency!
      validate_budget!
      @resolved_non_secret = deep_freeze(resolved_non_secret_hash)
      @fingerprint = Bridge::CanonicalJSON.sha256(@resolved_non_secret).freeze
      deep_freeze_instance
    end

    def profile_name
      @profile_name
    end

    def profile(name = profile_name)
      @profiles.fetch(name.to_s) { raise InvalidConfiguration.new("config.unknown_profile") }
    end

    def state_dir
      Pathname.new(@paths.fetch("state_dir"))
    end

    def database_path
      Pathname.new(@paths.fetch("database"))
    end

    def fingerprint
      @fingerprint
    end

    def to_h
      @resolved_non_secret
    end

    # Compatibility aliases used by orchestration code and configuration
    # callers that prefer descriptive names.
    alias calendar_profiles profiles
    alias source_profiles sources

    private

    def resolve_runtime(raw, env)
      runtime = fetch_hash(raw, "runtime")
      runtime = runtime.merge("timezone" => raw["timezone"]) if raw["timezone"]
      runtime = runtime.merge("profile" => raw["profile"]) if raw["profile"].is_a?(String)
      runtime["profile"] ||= env["CYBORG_PROFILE"]
      runtime["timezone"] ||= env["CYBORG_TIMEZONE"]
      runtime["timezone"] ||= DEFAULT_TIMEZONE
      runtime
    end

    def resolve_paths(raw, env)
      paths = fetch_hash(raw, "paths")
      state_dir = env["CYBORG_STATE_DIR"] || env["CYBORG_STATE"] || paths["state_dir"]
      state_dir ||= File.join(env.fetch("HOME", Dir.home), "Library", "Application Support", "CYBORG")
      state_dir = Pathname.new(state_dir.to_s).expand_path.to_s
      resolve_path = lambda do |value|
        pathname = Pathname.new(value.to_s)
        pathname.absolute? ? pathname.to_s : File.join(state_dir, pathname.to_s)
      end
      {
        "state_dir" => state_dir,
        "database" => resolve_path.call(env["CYBORG_DATABASE"] || paths["database"] || File.join(state_dir, "cyborg.sqlite3")),
        "artifacts" => resolve_path.call(env["CYBORG_ARTIFACT_DIR"] || paths["artifacts"] || paths["artifact_dir"] || File.join(state_dir, "artifacts")),
        "logs" => resolve_path.call(env["CYBORG_LOG_DIR"] || paths["logs"] || paths["log_dir"] || File.join(state_dir, "logs")),
        "lock" => resolve_path.call(env["CYBORG_LOCK_FILE"] || paths["lock"] || paths["lock_file"] || File.join(state_dir, "state.lock"))
      }
    end

    def resolve_profiles(raw, runtime)
      source = fetch_hash(raw, "calendar")
      configured = source["profiles"]
      configured = raw["profiles"] if !configured.is_a?(Hash) && raw["profiles"].is_a?(Hash)
      configured = {"default" => {}} unless configured.is_a?(Hash) && !configured.empty?
      defaults = source.reject { |key, _value| key.to_s == "profiles" }
      configured.each_with_object({}) do |(name, value), result|
        unless value.is_a?(Hash)
          raise_invalid("config.invalid_profile", "calendar profile must be a table")
        end
        result[name.to_s] = build_profile(name.to_s, defaults.merge(value), runtime)
      end
    end

    def build_profile(name, values, runtime)
      working_hours = values["working_hours"] || fetch_hash(@raw, "working_hours")
      working_hours = normalize_working_hours(working_hours)
      weekend_days = values.key?("weekend_days") ? values["weekend_days"] : ["saturday", "sunday"]
      weekend_days = Array(weekend_days).map { |day| normalize_weekday(day) }
      if weekend_days.uniq.length == 7
        raise_invalid("config.no_business_day", "calendar profile has no possible business day")
      end
      timezone = (values["timezone"] || runtime["timezone"] || DEFAULT_TIMEZONE).to_s
      begin
        TZInfo::Timezone.get(timezone)
      rescue TZInfo::InvalidTimezoneIdentifier
        raise_invalid("config.invalid_timezone", "unknown timezone")
      end

      holiday_table = values["holidays"].is_a?(Hash) ? values["holidays"] : {}
      observed_value = values.key?("observed") ? values["observed"] : holiday_table["observed"]
      observed = observed_value.nil? ? true : boolean(observed_value)
      easter = if values.key?("easter")
        boolean(values["easter"])
      elsif values.key?("observe_easter")
        boolean(values["observe_easter"])
      elsif holiday_table.key?("easter")
        boolean(holiday_table["easter"])
      else
        false
      end
      holidays = values.key?("holidays") ? values["holidays"] : nil
      if holidays.is_a?(Hash)
        holidays = holiday_table["include"] || holiday_table["names"] || holiday_table.keys.filter_map do |key|
          next if %w[observed easter include names].include?(key.to_s)
          key.to_s if boolean(holiday_table[key])
        end
      end
      holidays = Array(holidays).map { |holiday| holiday.to_s }
      additions = Array(values["add_holidays"] || values["additional_holidays"] || holiday_table["add"] || holiday_table["additional"]).map(&:to_s)
      removals = Array(values["remove_holidays"] || values["excluded_holidays"] || holiday_table["remove"] || holiday_table["excluded"]).map(&:to_s)
      holidays = DEFAULT_PROFILE_HOLIDAYS if holidays.empty?
      overrides = values["overrides"] || values["holiday_overrides"] || {}
      unless overrides.is_a?(Hash)
        raise_invalid("config.invalid_holiday_overrides", "holiday overrides must be a table")
      end

      Profile.new(
        name,
        timezone,
        deep_freeze(stringify_keys(working_hours)),
        weekend_days.freeze,
        deep_freeze(holidays),
        observed,
        easter,
        deep_freeze(stringify_keys(overrides)),
        deep_freeze(additions),
        deep_freeze(removals),
        integer(values["window_before_business_days"] || values.dig("window", "before_business_days") || 1, "config.invalid_window"),
        integer(values["window_after_business_days"] || values.dig("window", "after_business_days") || 1, "config.invalid_window")
      )
    end

    def normalize_working_hours(value)
      value = DEFAULT_WORKING_HOURS if value.nil? || (value.is_a?(Hash) && value.empty?)
      unless value.is_a?(Hash)
        raise_invalid("config.invalid_working_hours", "working hours must be a table")
      end

      direct_interval = value.key?("start") || value.key?("end")
      if direct_interval
        unless value.key?("start") && value.key?("end")
          raise_invalid("config.invalid_working_hours", "working hours require start and end")
        end
        return deep_freeze(normalize_working_interval(value))
      end

      result = {}
      value.each do |day, interval|
        weekday = normalize_weekday_name(day)
        result[weekday] = if interval.nil? || interval == false
          nil
        else
          normalize_working_interval(interval)
        end
      end
      if result.empty? || result.values.none?
        raise_invalid("config.no_business_day", "calendar profile has no working hours")
      end
      deep_freeze(result)
    rescue InvalidConfiguration
      raise
    rescue StandardError
      raise_invalid("config.invalid_working_hours", "working hours are malformed")
    end

    def normalize_working_interval(value)
      start_value, end_value = case value
      when Hash
        [value["start"] || value[:start], value["end"] || value[:end]]
      when Array
        [value[0], value[1]]
      when String
        value.split(/\s*-\s*/, 2)
      else
        [nil, nil]
      end
      unless start_value && end_value
        raise_invalid("config.invalid_working_hours", "working hours require start and end")
      end

      start_minutes = parse_working_time(start_value)
      end_minutes = parse_working_time(end_value)
      if start_minutes >= end_minutes
        raise_invalid("config.invalid_working_hours", "working hours must be ordered")
      end
      {"start" => format_working_time(start_minutes), "end" => format_working_time(end_minutes)}
    end

    def parse_working_time(value)
      text = value.to_s
      match = /\A(?:([01]\d|2[0-3]):([0-5]\d)|(24):([0]{2}))\z/.match(text)
      raise_invalid("config.invalid_working_hours", "working hours must use HH:MM") unless match
      return 24 * 60 if match[3]

      (match[1].to_i * 60) + match[2].to_i
    end

    def format_working_time(minutes)
      format("%02d:%02d", minutes / 60, minutes % 60)
    end

    def normalize_weekday_name(day)
      index = normalize_weekday(day)
      WEEKDAY_NAMES.fetch(index)
    end

    def resolve_sources(raw)
      configured = raw["sources"] || raw["source"] || {}
      unless configured.is_a?(Hash)
        raise_invalid("config.invalid_sources", "sources must be a table")
      end
      configured.each_with_object({}) do |(name, value), result|
        unless value.is_a?(Hash)
          raise_invalid("config.invalid_source", "source configuration must be a table")
        end
        adapter = (value["adapter"] || value["type"] || name).to_s
        unless %w[github local_git git].include?(adapter)
          raise_invalid("config.invalid_enum", "unsupported source adapter")
        end
        repositories = value["repositories"] || value["repository_roots"] || value["roots"] || []
        repositories = Array(repositories).map do |repository|
          if repository.is_a?(Hash)
            path = repository["path"] || repository["root"]
            required = repository.key?("required") ? boolean(repository["required"]) : true
            {"path" => path.to_s, "required" => required}
          else
            {"path" => repository.to_s, "required" => true}
          end
        end
        limits = fetch_hash(value, "limits")
        %w[max_records max_pages max_bytes max_seconds max_repositories command_timeout_seconds].each do |key|
          limits[key] = value[key] if value.key?(key)
        end
        limits = limits.each_with_object({}) do |(key, limit), out|
          out[key.to_s] = integer(limit, "config.invalid_source_limit")
        end
        result[name.to_s] = Source.new(
          name.to_s,
          adapter,
          value.key?("enabled") ? boolean(value["enabled"]) : false,
          value["account"]&.to_s,
          deep_freeze(repositories),
          deep_freeze(Array(value["channels"]).map(&:to_s)),
          deep_freeze(fetch_hash(value, "filters")),
          deep_freeze(limits),
          value.key?("required") ? boolean(value["required"]) : false
        )
      end
    end

    def resolve_budget(raw)
      values = fetch_hash(raw, "budget")
      ceiling = values["ceiling_micros"] || values["max_micros"] || values["run_ceiling_micros"] || DEFAULT_CEILING_MICROS
      Budget.new(integer(ceiling, "config.invalid_budget"), 0)
    end

    def resolve_cache(raw)
      values = fetch_hash(raw, "cache")
      ordinary = values["ordinary_ttl_seconds"] || values.dig("ordinary", "ttl_seconds") || values["ttl_seconds"] || DEFAULT_ORDINARY_CACHE_TTL_SECONDS
      expensive = values["expensive_ttl_seconds"] || values.dig("expensive", "ttl_seconds") || DEFAULT_EXPENSIVE_CACHE_TTL_SECONDS
      ordinary = integer(ordinary, "config.invalid_cache_ttl")
      expensive = integer(expensive, "config.invalid_cache_ttl")
      raise_invalid("config.expensive_cache_too_short") if expensive < 10_800
      Cache.new(ordinary, expensive)
    end

    def resolve_timeouts(raw, runtime)
      values = fetch_hash(raw, "timeouts")
      lease = runtime["lease_timeout_seconds"] || values["lease_timeout_seconds"] || values["lease_seconds"] || DEFAULT_LEASE_TIMEOUT_SECONDS
      analysis = runtime["analysis_timeout_seconds"] || values["analysis_timeout_seconds"] || values["analysis_seconds"] || DEFAULT_ANALYSIS_TIMEOUT_SECONDS
      Timeouts.new(integer(lease, "config.invalid_timeout"), integer(analysis, "config.invalid_timeout"))
    end

    def validate_required_sections!
      required = @raw["required"]
      return unless required
      unless required.is_a?(Hash)
        raise_invalid("config.unknown_required_section")
      end
      known = %w[paths repositories sources]
      unknown = required.keys.map(&:to_s) - known
      raise_invalid("config.unknown_required_section") unless unknown.empty?
    end

    def validate_required_paths!
      @sources.each_value do |source|
        source.repositories.each do |repository|
          next unless repository["required"]
          path = Pathname.new(repository["path"]).expand_path
          unless path.directory?
            raise_invalid("config.required_path_missing", "required repository root does not exist")
          end
        end
      end
      repository_requirements = fetch_hash(@raw, "repositories")["required"]
      repository_requirements = fetch_hash(@raw, "required")["repositories"] if repository_requirements.nil?
      Array(repository_requirements).each do |repository|
        path = repository.is_a?(Hash) ? (repository["path"] || repository["root"]) : repository
        next if repository.is_a?(Hash) && repository.key?("required") && !boolean(repository["required"])
        next if path.nil?
        unless Pathname.new(path.to_s).expand_path.directory?
          raise_invalid("config.required_path_missing", "required repository root does not exist")
        end
      end
    end

    def validate_timeout_consistency!
      return if @timeouts.lease_timeout_seconds > @timeouts.analysis_timeout_seconds

      raise_invalid("config.lease_too_short", "run lease must exceed analysis timeout")
    end

    def validate_budget!
      required = required_reservation_micros
      @budget = Budget.new(@budget.ceiling_micros, required)
      return if @budget.ceiling_micros >= required

      raise_invalid("config.budget_too_low", "budget cannot cover required reservations")
    end

    def raise_invalid(code, message = nil)
      raise InvalidConfiguration.new(code, message)
    end

    def required_reservation_micros
      analysis = fetch_hash(@raw, "analysis")
      total = integer(analysis["required_reservation_micros"] || 0, "config.invalid_budget")
      budget = fetch_hash(@raw, "budget")
      total += integer(budget["required_reservation_micros"] || budget["required_micros"] || 0, "config.invalid_budget")
      tasks = analysis["tasks"] || @raw["tasks"]
      if tasks.is_a?(Hash)
        tasks.each_value do |task|
          next unless task.is_a?(Hash) && boolean(task["required"])
          total += integer(task["reservation_micros"] || task["budget_micros"] || 0, "config.invalid_budget")
        end
      elsif tasks.is_a?(Array)
        tasks.each do |task|
          next unless task.is_a?(Hash) && boolean(task["required"])
          total += integer(task["reservation_micros"] || task["budget_micros"] || 0, "config.invalid_budget")
        end
      end
      total += integer(fetch_hash(@raw, "required")["reservation_micros"] || 0, "config.invalid_budget")
      total
    end

    def resolved_non_secret_hash
      resolved = @raw.each_with_object({}) { |(key, value), result| result[key] = value }
      calendar = fetch_hash(resolved, "calendar")
      calendar["default_profile"] = @profile_name
      calendar["profiles"] = @profiles.transform_values { |profile| profile_to_h(profile) }
      resolved.merge(
        "runtime" => @runtime,
        "paths" => @paths,
        "sources" => @sources.transform_values { |source| source_to_h(source) },
        "budget" => {"ceiling_micros" => @budget.ceiling_micros, "required_reservation_micros" => @budget.required_reservation_micros},
        "cache" => {"ordinary_ttl_seconds" => @cache.ordinary_ttl_seconds, "expensive_ttl_seconds" => @cache.expensive_ttl_seconds},
        "timeouts" => {"lease_timeout_seconds" => @timeouts.lease_timeout_seconds, "analysis_timeout_seconds" => @timeouts.analysis_timeout_seconds},
        "calendar" => calendar,
        "analysis" => @analysis,
        "renderer" => @renderer,
        "output" => @output,
        "footer" => @footer,
        "selected_profile" => @profile_name
      )
    end

    def profile_to_h(profile)
      {
        "name" => profile.name,
        "timezone" => profile.timezone,
        "working_hours" => profile.working_hours,
        "weekend_days" => profile.weekend_days,
        "holidays" => profile.holidays,
        "observed" => profile.observed,
        "easter" => profile.easter,
        "overrides" => profile.overrides,
        "holiday_additions" => profile.holiday_additions,
        "holiday_removals" => profile.holiday_removals,
        "window_before_business_days" => profile.window_before_business_days,
        "window_after_business_days" => profile.window_after_business_days
      }
    end

    def source_to_h(source)
      {
        "name" => source.name, "adapter" => source.adapter, "enabled" => source.enabled,
        "account" => source.account, "repositories" => source.repositories,
        "channels" => source.channels, "filters" => source.filters,
        "limits" => source.limits, "required" => source.required
      }
    end

    def fetch_hash(hash, *keys)
      keys.each do |key|
        value = hash[key]
        return value.dup if value.is_a?(Hash)
      end
      {}
    end

    def stringify_keys(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, item), result| result[key.to_s] = stringify_keys(item) }
      when Array
        value.map { |item| stringify_keys(item) }
      else
        value
      end
    end

    def deep_freeze(value)
      case value
      when Hash
        value.each { |key, item| deep_freeze(key); deep_freeze(item) }
      when Array
        value.each { |item| deep_freeze(item) }
      end
      value.freeze
    end

    def deep_freeze_instance
      instance_variables.each do |name|
        value = instance_variable_get(name)
        deep_freeze(value) unless name == :@fingerprint
      end
      freeze
    end

    def boolean(value)
      return value if value == true || value == false
      return true if %w[true yes on 1].include?(value.to_s.downcase)
      return false if %w[false no off 0].include?(value.to_s.downcase)
      raise_invalid("config.invalid_boolean")
    end

    def integer(value, code)
      number = Integer(value)
      raise_invalid(code) if number.negative?
      number
    rescue ArgumentError, TypeError
      raise_invalid(code)
    end

    def normalize_weekday(day)
      case day.to_s.downcase
      when "sunday", "sun", "0" then 0
      when "monday", "mon", "1" then 1
      when "tuesday", "tue", "2" then 2
      when "wednesday", "wed", "3" then 3
      when "thursday", "thu", "4" then 4
      when "friday", "fri", "5" then 5
      when "saturday", "sat", "6" then 6
      else raise_invalid("config.invalid_weekend_day")
      end
    end
  end

  Config::Profile = Profile
  Config::Source = Source
  Config::Budget = Budget
  Config::Cache = Cache
  Config::Timeouts = Timeouts

  class Budget
    alias max_micros ceiling_micros
    alias run_ceiling_micros ceiling_micros
  end

  class Cache
    alias ordinary_ttl ordinary_ttl_seconds
    alias expensive_ttl expensive_ttl_seconds
  end

  class Source
    def [](key)
      return public_send(key) if members.include?(key.to_sym)
      limits[key.to_s]
    end

    %w[max_records max_pages max_bytes max_seconds max_repositories command_timeout_seconds].each do |limit|
      define_method(limit) { limits[limit] }
    end
  end
end
