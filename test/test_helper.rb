# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "tmpdir"
require "yaml"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "cyborg/memory_candidates"

module MemoryCandidateTestHelpers
  def with_env(overrides)
    previous = overrides.to_h { |key, _value| [key, ENV[key]] }
    overrides.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def build_memory_project
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "docs/memory"))
      yield root
    end
  end

  def write_transcript(root, messages)
    path = File.join(root, "transcript.jsonl")
    records = messages.map do |role, text|
      {"type" => role, "message" => {"content" => text}}
    end
    File.write(path, records.map { |record| JSON.generate(record) }.join("\n") + "\n")
    path
  end

  def read_memory_entry(path)
    contents = File.read(path)
    match = contents.match(/\A---\n(.*?)\n---\n/m)
    [YAML.safe_load(match[1]), contents]
  end
end

class Minitest::Test
  include MemoryCandidateTestHelpers
end
