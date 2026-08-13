# frozen_string_literal: true

require_relative "../test_helper"
require "rake"
load File.expand_path("../../Rakefile", __dir__)

class CyborgTask17DiscoveryTest < Minitest::Test
  def test_default_rake_pattern_discovers_all_task17_system_files
    discovered = Rake::FileList["test/**/*_test.rb"].to_a
    task17_files = Dir[File.expand_path("*_test.rb", __dir__)].select { |path| File.basename(path).include?("acceptance") || File.basename(path).include?("repeated") || File.basename(path).include?("failure_isolation") }
    refute_empty task17_files
    task17_files.each { |path| assert_includes discovered, path.sub(%r{\A#{Regexp.escape(Dir.pwd)}/}, "") }
  end
end
