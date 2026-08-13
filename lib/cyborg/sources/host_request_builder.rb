# frozen_string_literal: true

require "securerandom"
require_relative "contracts"

module Cyborg
  # Builds declarative host requests from trusted registration metadata. No
  # source payload is consulted while constructing an operation or its bounds.
  class HostRequestBuilder
    def call(run:, registrations:, context:)
      Array(registrations).each_with_object([]) do |registration, requests|
        next unless registration.transport.to_s == "host_bridge"
        next if context.source_name && registration.source_name != context.source_name
        next if context.account_identity && registration.account_identity && registration.account_identity != context.account_identity

        capabilities = Array(context.capabilities)
        capabilities = registration.capabilities if capabilities.empty?
        capabilities.each do |capability|
          operation = registration.operation_for(capability)
          requests << RetrievalRequest.new(
            id: SecureRandom.uuid,
            run_id: run.id,
            source_name: registration.source_name,
            account_identity: registration.account_identity,
            capability: capability.to_s,
            adapter_version: registration.adapter_version,
            window_start_utc: context.window_start_utc,
            window_end_utc: context.window_end_utc,
            display_timezone: context.display_timezone,
            prior_cursor: context.prior_cursor,
            operation: operation,
            parameters: registration.parameters_for(capability).merge(
              "window_start_utc" => context.window_start_utc,
              "window_end_utc" => context.window_end_utc,
              "filters" => registration.filters.merge(context.filters)
            ),
            max_pages: bounded(context.max_pages, registration.max_pages),
            max_records: bounded(context.max_records, registration.max_records),
            max_response_bytes: bounded(context.max_response_bytes, registration.max_response_bytes),
            required: registration.required?
          )
        end
      end
    end

    private

    def bounded(context_limit, registration_limit)
      return registration_limit if context_limit.nil?
      return context_limit if registration_limit.nil?

      [context_limit, registration_limit].min
    end
  end
end
