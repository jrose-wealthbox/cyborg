# frozen_string_literal: true

module Cyborg
  module Presentation
    class MarkdownRenderer
      def render(view_model)
        lines = []
        sections = Array(view_model.fetch("sections", []))
        lines << "# CYBORG"
        sections.each do |section|
          heading = section.fetch("heading", section.fetch("name"))
          lines << "## #{heading}"
          if section.fetch("name") == "SOURCE HEALTH"
            Array(view_model["source_health"]).each do |health|
              details = [health["status"], "last fresh refresh #{health["last_fresh_refresh"]}",
                         "cached=#{health["data_status"] == "cached"}", health["remediation"], health["inference_impact"]].compact
              lines << "- #{health["source"]} (#{health["account"]}): #{details.join("; ")}"
            end
          end
          Array(section.fetch("items", [])).each do |item|
            markers = Array(item["markers"]).join
            prefix = markers.empty? ? "" : "#{markers} "
            links = Array(item["links"]).map { |link| "[source](#{link})" }.join(" ")
            details = [item["state"], item["age"], item["confidence"]].compact.map(&:to_s)
            details << links unless links.empty?
            suffix = details.empty? ? "" : " — #{details.join(" ")}"
            lines << "- #{prefix}#{item.fetch("summary", "")} [#{item.fetch("id", "")}]#{suffix}"
          end
        end
        warnings = Array(view_model["warnings"])
        unless warnings.empty?
          lines << "## WARNINGS"
          warnings.each { |warning| lines << "- #{warning}" }
        end
        usage = view_model["usage"] || {}
        lines << "Cost certainty: #{usage["certainty"]}" if usage["certainty"]
        lines << view_model["footer"].to_s if view_model["footer"]
        lines.join("\n") + "\n"
      end
    end
  end
end
