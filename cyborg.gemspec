# frozen_string_literal: true

require_relative "lib/cyborg/version"

Gem::Specification.new do |spec|
  spec.name = "cyborg"
  spec.version = Cyborg::VERSION
  spec.authors = ["CYBORG contributors"]
  spec.summary = "A local executive-summary dashboard"
  spec.description = "A headless Ruby application for bounded, auditable personal briefings."
  spec.homepage = "https://github.com/openai/cyborg"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0"

  spec.files = Dir[
    "Gemfile",
    "Rakefile",
    "cyborg.gemspec",
    "bin/*",
    "lib/**/*.rb"
  ]
  spec.bindir = "bin"
  spec.executables = ["cyborg"]
  spec.require_paths = ["lib"]

  spec.add_dependency "sequel"
  spec.add_dependency "sqlite3"
  spec.add_dependency "toml-rb"
  spec.add_dependency "tzinfo"

  spec.add_development_dependency "minitest"
  spec.add_development_dependency "rake"
end
