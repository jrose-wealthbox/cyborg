# frozen_string_literal: true

require "time"
require "date"

module Cyborg
  module Analysis
    CAPABILITIES = %w[
      cheap_structured_extraction
      medium_reasoning
      high_reasoning
    ].freeze
    USAGE_CERTAINTIES = %w[reserved provider_reported locally_estimated unknown].freeze
    DEFAULT_CEILING_MICROS = 5_000_000
    PRICE_CATALOG_MAX_AGE_SECONDS = 7 * 24 * 60 * 60

    module Contracts
      module_function

      def immutable(value)
        case value
        when Hash
          value.each { |key, item| immutable(key); immutable(item) }
        when Array
          value.each { |item| immutable(item) }
        end
        value.freeze
      end

      def value_class(name, members, defaults: {}, aliases: {}, validator: nil, &block)
        klass = Data.define(*members)
        generated_new = klass.method(:new)
        constructor = Module.new do
          define_method(:new) do |*args, **kwargs|
            values = if args.empty?
              unknown = kwargs.keys.map(&:to_sym) - members - aliases.keys
              raise ArgumentError, "unknown #{name} fields: #{unknown.join(", ")}" unless unknown.empty?

              members.map do |member|
                alias_keys = aliases.select { |_alias, canonical| canonical == member }.keys
                supplied_aliases = alias_keys.select { |key| kwargs.key?(key) }
                if kwargs.key?(member) && !supplied_aliases.empty?
                  raise ArgumentError, "duplicate #{name} field: #{member}"
                end
                kwargs.key?(member) ? kwargs[member] : kwargs.fetch(supplied_aliases.first, defaults[member])
              end
            else
              raise ArgumentError, "#{name} expects #{members.length} values" unless kwargs.empty? && args.length == members.length

              args
            end
            values = validator.call(values) if validator
            values.each { |value| Contracts.immutable(value) unless value.nil? }
            generated_new.call(*values)
          end
        end
        klass.singleton_class.prepend(constructor)
        klass.class_eval(&block) if block
        klass
      end

      def strict_integer(value, field, minimum: 0)
        unless value.is_a?(Integer) && value >= minimum
          raise ArgumentError, "#{field} must be an integer greater than or equal to #{minimum}"
        end

        value
      end

      def nonblank(value, field)
        unless value.is_a?(String) && !value.strip.empty?
          raise ArgumentError, "#{field} must be a nonblank String"
        end

        value
      end

      def canonical_time(value, field)
        return nil if value.nil?
        return value.utc if value.is_a?(Time)

        Time.iso8601(value.to_s).utc
      rescue ArgumentError, TypeError
        raise ArgumentError, "#{field} must be a Time or RFC3339 timestamp"
      end

      def canonical_date(value, field)
        return nil if value.nil?
        return value.iso8601 if value.is_a?(Date)

        Date.iso8601(value.to_s).iso8601
      rescue ArgumentError, TypeError
        raise ArgumentError, "#{field} must be an ISO 8601 date"
      end
    end

    PriceCatalog = Contracts.value_class(
      "PriceCatalog",
      %i[provider model input_micros_per_token output_micros_per_token effective_date last_verified_at source_url],
      aliases: {verified_at: :last_verified_at},
      defaults: {provider: nil, model: nil, input_micros_per_token: nil, output_micros_per_token: nil,
                 effective_date: nil, last_verified_at: nil, source_url: nil},
      validator: lambda do |values|
        provider, model, input_rate, output_rate, effective_date, verified_at, source_url = values
        Contracts.nonblank(provider, "provider")
        Contracts.nonblank(model, "model")
        Contracts.strict_integer(input_rate, "input_micros_per_token")
        Contracts.strict_integer(output_rate, "output_micros_per_token")
        values[4] = Contracts.canonical_date(effective_date, "effective_date")
        values[5] = Contracts.canonical_time(verified_at, "verified_at")
        values[6] = source_url.to_s unless source_url.nil?
        values
      end
    ) do
      alias verified_at last_verified_at

      def stale?(now: Time.now.utc, max_age_seconds: PRICE_CATALOG_MAX_AGE_SECONDS)
        return true if last_verified_at.nil?

        Contracts.canonical_time(now, "now") - last_verified_at > Integer(max_age_seconds)
      end

      def warning_codes(now: Time.now.utc)
        stale?(now:) ? ["analysis.stale_price_catalog"].freeze : [].freeze
      end

      def cost_micros(input_tokens:, output_tokens:)
        Contracts.strict_integer(input_tokens, "input_tokens") * input_micros_per_token +
          Contracts.strict_integer(output_tokens, "output_tokens") * output_micros_per_token
      end
    end

    Reservation = Contracts.value_class(
      "Reservation",
      %i[cost_micros input_tokens output_tokens input_micros_per_token output_micros_per_token],
      defaults: {cost_micros: nil, input_tokens: nil, output_tokens: nil,
                  input_micros_per_token: nil, output_micros_per_token: nil},
      validator: lambda do |values|
        cost, input_tokens, output_tokens, input_rate, output_rate = values
        values[1] = Contracts.strict_integer(input_tokens, "input_tokens") unless input_tokens.nil?
        values[2] = Contracts.strict_integer(output_tokens, "output_tokens") unless output_tokens.nil?
        values[3] = Contracts.strict_integer(input_rate, "input_micros_per_token") unless input_rate.nil?
        values[4] = Contracts.strict_integer(output_rate, "output_micros_per_token") unless output_rate.nil?
        if cost.nil?
          unless values[1] && values[2] && values[3] && values[4]
            raise ArgumentError, "reservation requires cost_micros or token/rate values"
          end
          cost = values[1] * values[3] + values[2] * values[4]
          values[0] = cost
        else
          values[0] = Contracts.strict_integer(cost, "cost_micros")
          token_rates = values[1..4]
          if token_rates.any? && !token_rates.all?(&:nil?)
            raise ArgumentError, "reservation token/rate values must be complete"
          elsif token_rates.all? && values[0] != (values[1] * values[3] + values[2] * values[4])
            raise ArgumentError, "reservation cost_micros does not match token/rate values"
          end
        end
        values
      end
    ) do
      alias amount_micros cost_micros

      def to_h
        members.each_with_object({}) { |member, result| result[member] = public_send(member) }
      end
    end

    AnalysisTask = Contracts.value_class(
      "AnalysisTask",
      %i[id capability dependency_ids required packet_fingerprint maximum_output_bytes reservation],
      defaults: {dependency_ids: [], required: false},
      validator: lambda do |values|
        id, capability, dependency_ids, required, packet_fingerprint, maximum_output_bytes, reservation = values
        Contracts.nonblank(id, "id")
        unless CAPABILITIES.include?(capability.to_s)
          raise ArgumentError, "capability must be an abstract analysis capability"
        end
        values[1] = capability.to_s
        unless dependency_ids.is_a?(Array) && dependency_ids.all? { |item| item.is_a?(String) && !item.strip.empty? }
          raise ArgumentError, "dependency_ids must be an array of nonblank Strings"
        end
        values[2] = dependency_ids.map(&:to_s).uniq.sort
        raise ArgumentError, "required must be boolean" unless required == true || required == false
        Contracts.nonblank(packet_fingerprint, "packet_fingerprint")
        Contracts.strict_integer(maximum_output_bytes, "maximum_output_bytes", minimum: 1)
        values[6] = reservation.is_a?(Reservation) ? reservation : Reservation.new(**reservation.to_h.transform_keys(&:to_sym)) if reservation.respond_to?(:to_h)
        raise ArgumentError, "reservation must be a Reservation" unless values[6].is_a?(Reservation)
        values
      end
    ) do
      alias task_id id

      def to_h
        members.each_with_object({}) { |member, result| result[member] = public_send(member) }
      end
    end

    AnalysisOutcome = Contracts.value_class(
      "AnalysisOutcome", %i[claims usage backend_metadata],
      defaults: {claims: [], usage: {}, backend_metadata: {}},
      validator: lambda do |values|
        values[0] = Array(values[0])
        values[1] = {} if values[1].nil?
        values[2] = {} if values[2].nil?
        raise ArgumentError, "usage must be a Hash" unless values[1].is_a?(Hash)
        raise ArgumentError, "backend_metadata must be a Hash" unless values[2].is_a?(Hash)
        values
      end
    )

    UsageRecord = Contracts.value_class(
      "UsageRecord",
      %i[id run_id task_id session_id parent_session_id reserved_cost_micros input_tokens output_tokens cost_micros certainty created_at],
      defaults: {task_id: nil, session_id: nil, parent_session_id: nil, reserved_cost_micros: 0,
                  input_tokens: nil, output_tokens: nil, cost_micros: nil, certainty: "reserved", created_at: nil},
      validator: lambda do |values|
        id, run_id, _task_id, _session_id, _parent_session_id, reserved, input, output, cost, certainty, created = values
        Contracts.nonblank(id, "id")
        Contracts.nonblank(run_id, "run_id")
        Contracts.strict_integer(reserved, "reserved_cost_micros")
        Contracts.strict_integer(input, "input_tokens") unless input.nil?
        Contracts.strict_integer(output, "output_tokens") unless output.nil?
        Contracts.strict_integer(cost, "cost_micros") unless cost.nil?
        unless USAGE_CERTAINTIES.include?(certainty.to_s)
          raise ArgumentError, "unsupported usage certainty"
        end
        if %w[provider_reported locally_estimated].include?(certainty.to_s) && cost.nil?
          raise ArgumentError, "#{certainty} usage requires known cost_micros"
        end
        if certainty.to_s == "reserved" && [input, output, cost].any? { |value| !value.nil? }
          raise ArgumentError, "reserved usage cannot include actual tokens or cost"
        end
        values[9] = certainty.to_s
        values[10] = Contracts.canonical_time(created, "created_at") if created
        values
      end
    ) do
      def reported?
        certainty == "provider_reported"
      end
    end

    UsageSummary = Contracts.value_class(
      "UsageSummary",
      %i[records reserved_cost_micros reported_cost_micros provider_reported_cost_micros locally_estimated_cost_micros unknown_cost_micros certainty warnings],
      defaults: {records: [], reserved_cost_micros: 0, reported_cost_micros: 0,
                 provider_reported_cost_micros: 0, locally_estimated_cost_micros: 0,
                 unknown_cost_micros: 0, certainty: "unknown", warnings: []}
    )

    ReservationEntry = Contracts.value_class(
      "ReservationEntry", %i[task_id reserved_micros status reason],
      defaults: {reserved_micros: 0, status: "reserved", reason: nil}
    ) do
      def reserved?
        status == "reserved"
      end
    end
  end

  # Keep the public contract available at the top level, matching the bridge
  # and domain value objects used elsewhere in CYBORG.
  AnalysisOutcome = Analysis::AnalysisOutcome
  AnalysisTask = Analysis::AnalysisTask
end
