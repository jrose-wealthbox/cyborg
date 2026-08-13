# frozen_string_literal: true

require "json"

module Cyborg
  module Presentation
    class JsonRenderer
      def render(view_model)
        JSON.generate(view_model)
      end
    end
  end
end
