# frozen_string_literal: true

require "time"
require "uri"
require_relative "../redactor"

module Cyborg
  module Presentation
    class ViewModelBuilder
      SECTION_ORDER = ["SOURCE HEALTH", "DO", "RESPOND", "PREP", "WAITING ON", "DECIDE", "CHANGED", "FYI"].freeze
      TERMINAL_STATES = %w[done dismissed superseded].freeze

      def initialize(now: nil, clock: nil, footer: nil, recency_markers: true, urgency_markers: true,
                     show_recency_markers: nil, show_urgency_markers: nil, trusted_hosts: [], redactor: nil)
        @now = now || (clock.respond_to?(:now) ? clock.now : Time.now.utc)
        @now = @now.is_a?(Time) ? @now.utc : Time.iso8601(@now.to_s).utc
        @footer = footer
        @recency_markers = show_recency_markers.nil? ? recency_markers : show_recency_markers
        @urgency_markers = show_urgency_markers.nil? ? urgency_markers : show_urgency_markers
        @trusted_hosts = normalize_hosts(trusted_hosts)
        @redactor = redactor || Cyborg::Redactor.new
      end

      def call(run:, snapshots:, records:, actions:, warnings:, usage:)
        snapshots = Array(snapshots)
        health_degraded = snapshots.any? { |snapshot| degraded_snapshot?(snapshot) }
        sections = SECTION_ORDER.map do |name|
          items = if name == "SOURCE HEALTH"
            []
          else
            action_items(actions, name) + record_items(records, name)
          end
          {"name" => name, "heading" => (health_degraded && name == "SOURCE HEALTH" ? "⚠️ SOURCE HEALTH" : name), "items" => items}
        end
        value = {
          "version" => "1.0",
          "run" => normalize_hash(run),
          "source_health" => health_summary(snapshots),
          "sections" => sections,
          "warnings" => Array(warnings).map(&:to_s).reject(&:empty?).uniq,
          "usage" => normalize_hash(usage || {}),
          "footer" => @footer
        }
        deep_freeze(value)
      end

      private

      def action_items(actions, section)
        Array(actions).filter_map do |raw|
          action = normalize_hash(raw)
          next unless section_for(action) == section
          next unless displayable?(action)

          action["displayable_action"] = true
          item = item_for(action, action_time(action))
          item["kind"] = "action"
          item["action_kind"] = string_value(action, "action_kind")
          item["state"] = string_value(action, "user_state") || string_value(action, "state") || "open"
          item["state_version"] = action["state_version"] if action.key?("state_version")
          item["confidence"] = action["confidence"] if action.key?("confidence")
          item["links"] = safe_links([action["source_url"], *Array(action["links"])])
          item
        end
      end

      def record_items(records, section)
        Array(records).filter_map do |raw|
          record = normalize_hash(raw)
          next unless section_for(record) == section

          item = item_for(record, selected_time(record))
          item["kind"] = "record"
          item["record_kind"] = string_value(record, "record_kind") || string_value(record, "kind")
          item["links"] = safe_links([record["deep_link"], *Array(record["links"])])
          item["first_seen_after_baseline"] = true if record["first_seen_after_baseline"] == true
          item
        end
      end

      def item_for(value, timestamp)
        age = Age.format(timestamp, now: @now)
        seconds = age_seconds(timestamp)
        fire = if seconds && seconds >= 0 && seconds < 1800
          "🔥🔥"
        elsif seconds && seconds >= 1800 && seconds < 5400
          "🔥"
        end
        new_marker = if fire.nil? && (value["first_seen_after_baseline"] == true || (seconds && seconds >= 7200 && seconds < 14_400))
          "🆕"
        end
        markers = []
        markers << fire if @recency_markers && fire
        markers << new_marker if @recency_markers && new_marker
        markers << "🚨" if @urgency_markers && value["displayable_action"] == true
        {
          "id" => string_value(value, "id"), "summary" => string_value(value, "summary") || "",
          "timestamp" => timestamp, "age" => age, "markers" => markers,
          "recency_marker" => (@recency_markers ? (fire || new_marker) : nil),
          "urgency_marker" => (@urgency_markers && value["displayable_action"] == true ? "🚨" : nil)
        }
      end

      def health_items(snapshots)
        snapshots.map do |raw|
          snapshot = normalize_hash(raw)
          {"id" => "source:#{snapshot["source_name"]}:#{snapshot["account_identity"]}",
           "summary" => health_summary_text(snapshot), "state" => snapshot["status"],
           "source" => snapshot["source_name"], "account" => snapshot["account_identity"],
           "cache_reason" => snapshot["cache_reason"], "last_fresh_refresh" => last_fresh_refresh(snapshot),
           "remediation" => snapshot["error_remediation"], "inference_impact" => inference_impact(snapshot),
           "markers" => [], "links" => []}
        end
      end

      def health_summary(snapshots)
        Array(snapshots).map do |raw|
          snapshot = normalize_hash(raw)
          {"source" => snapshot["source_name"], "account" => snapshot["account_identity"],
           "status" => effective_status(snapshot), "data_status" => snapshot["data_status"],
           "cache_reason" => snapshot["cache_reason"], "last_fresh_refresh" => last_fresh_refresh(snapshot),
           "remediation" => snapshot["error_remediation"], "inference_impact" => inference_impact(snapshot)}
        end
      end

      def health_summary_text(snapshot)
        status = effective_status(snapshot)
        text = "#{snapshot["source_name"]} (#{snapshot["account_identity"]}): #{status}"
        text += "; cached from #{last_fresh_refresh(snapshot) || "unknown"}" if snapshot["data_status"] == "cached"
        text += "; #{snapshot["error_remediation"]}" if snapshot["error_remediation"]
        text
      end

      def inference_impact(snapshot)
        return "none" if effective_status(snapshot) == "healthy"

        snapshot["inference_impact"] || "inference may be incomplete; verify before acting"
      end

      def degraded_snapshot?(snapshot)
        status = normalize_hash(snapshot)
        effective_status(status) != "healthy"
      end

      def effective_status(snapshot)
        status = string_value(snapshot, "status") || "failed"
        return "degraded" if string_value(snapshot, "cache_reason") == "failure_fallback"
        return "healthy" if status == "healthy" && %w[fresh cached].include?(string_value(snapshot, "data_status")) && string_value(snapshot, "cache_reason") != "failure_fallback"

        status
      end

      def displayable?(action)
        return false if TERMINAL_STATES.include?(string_value(action, "user_state"))
        return false unless string_value(action, "inference_status").nil? || string_value(action, "inference_status") == "active"
        snoozed = action["snoozed_until"]
        return false if snoozed && age_seconds(snoozed).to_i < 0

        true
      end

      def section_for(value)
        explicit = string_value(value, "section")
        return explicit if SECTION_ORDER.include?(explicit) && explicit != "SOURCE HEALTH"

        kind = (string_value(value, "action_kind") || string_value(value, "record_kind") || string_value(value, "kind") || "fyi").downcase
        return "DO" if %w[do follow_up act].include?(kind)
        return "RESPOND" if %w[respond reply review].include?(kind)
        return "PREP" if %w[prep prepare investigate].include?(kind)
        return "WAITING ON" if %w[waiting_on waiting wait].include?(kind)
        return "DECIDE" if kind == "decide"
        return "CHANGED" if kind == "changed"

        "FYI"
      end

      def action_time(value)
        value["last_seen_at"] || value["event_at"] || value["observed_at"] || value["first_seen_at"]
      end

      def selected_time(value)
        value["latest_reply_at"] || value["event_at"] || value["observed_at"]
      end

      def age_seconds(timestamp)
        return nil unless timestamp

        parsed = timestamp.is_a?(Time) ? timestamp.utc : Time.iso8601(timestamp.to_s).utc
        (@now - parsed).to_f
      rescue ArgumentError, TypeError
        nil
      end

      def normalize_hash(value)
        return {} if value.nil?
        return value.each_with_object({}) { |(key, item), result| result[key.to_s] = item } if value.is_a?(Hash)
        return value.to_h.each_with_object({}) { |(key, item), result| result[key.to_s] = item } if value.respond_to?(:to_h)

        {}
      end

      def string_value(hash, key)
        value = hash[key] || hash[key.to_sym]
        value.nil? ? nil : value.to_s
      end

      def safe_links(links)
        links.filter_map do |link|
          value = link.to_s
          next unless value.match?(/\Ahttps:\/\/[^\s]+\z/i)

          uri = URI.parse(value)
          next unless uri.scheme == "https" && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
          next unless @trusted_hosts.include?(uri.host.to_s.downcase)
          next if uri.path.to_s.match?(%r{(?:\A|/)(?:token|secret|password|credential|api[_-]?key)(?:[/=]|\z)}i)
          next unless @redactor.call(uri.to_s) == uri.to_s

          uri.to_s
        rescue URI::InvalidURIError
          nil
        end.uniq
      end

      def last_fresh_refresh(snapshot)
        explicit = snapshot["last_fresh_refresh"]
        return explicit unless explicit.nil? || explicit.to_s.empty?
        return snapshot["completed_at"] if snapshot["status"] == "healthy" && snapshot["data_status"] == "fresh" &&
          snapshot["cursor_disposition"] == "advance" && snapshot["proposed_cursor"].to_s != ""

        nil
      end

      def normalize_hosts(hosts)
        Array(hosts).filter_map do |host|
          value = host.to_s.strip.downcase
          next if value.empty?

          value = URI.parse(value).host if value.include?("://")
          next if value.to_s.empty? || value.include?("/") || value.include?(" ")

          value
        rescue URI::InvalidURIError
          nil
        end.uniq.freeze
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
    end
  end
end
