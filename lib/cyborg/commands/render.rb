# frozen_string_literal: true

module Cyborg
  module Commands
    class Render < Base
      def call(argv)
        options = parse_options(argv, optional: %w[run format])
        format = options.fetch("format", "markdown")
        raise UsageError.new("cli.invalid_format") unless %w[markdown json].include?(format)
        run = options["run"] ? run_repository.find(options.fetch("run")) : run_repository.latest_renderable
        raise PersistenceError.new("run.not_renderable") unless run
        presentation = Repositories::PresentationRepository.new(db).for_run(run_id: run.id, profile: run.profile).first
        raise PersistenceError.new("presentation.not_found") unless presentation
        view_model = JSON.parse(presentation.view_model_json)
        renderer = format == "json" ? Presentation::JsonRenderer.new : Presentation::MarkdownRenderer.new
        stdout.write(renderer.render(view_model))
        0
      end
    end
  end
end
