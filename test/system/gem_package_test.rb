# frozen_string_literal: true

require_relative "../test_helper"

require "open3"
require "rubygems/installer"
require "rubygems/package"
require "yaml"

class CyborgGemPackageTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("cyborg-gem-package", "/private/tmp")
    @repo = File.expand_path("../..", __dir__)
    @gemspec = File.expand_path("../../cyborg.gemspec", __dir__)
    @gem_path = File.join(@tmpdir, "cyborg-0.1.0.gem")
  end

  def teardown
    FileUtils.remove_entry(@tmpdir)
  end

  def test_built_gem_packages_migrations_and_init_runs_from_install
    build = run_gem("build", @gemspec, "--output=#{@gem_path}")
    assert build.fetch(:status).success?, build.fetch(:stderr)
    assert_path_exists @gem_path

    specification = run_gem("specification", @gem_path, "files", "--yaml")
    assert specification.fetch(:status).success?, specification.fetch(:stderr)
    packaged_files = YAML.safe_load(specification.fetch(:stdout))
    migration_files = Dir[File.expand_path("../../db/migrations/*.rb", __dir__)].map do |path|
      Pathname.new(path).relative_path_from(Pathname.new(File.expand_path("../..", __dir__))).to_s
    end
    assert_empty migration_files - packaged_files

    install_dir = File.join(@tmpdir, "gems")
    Gem::Installer.new(Gem::Package.new(@gem_path), install_dir:, ignore_dependencies: true, wrappers: true).install
    home = File.join(@tmpdir, "home")
    installed_bin = File.join(install_dir, "bin", "cyborg")
    init = run_installed(installed_bin, home, "init")
    assert init.fetch(:status).success?, init.fetch(:stderr)
    result = JSON.parse(init.fetch(:stdout))
    assert_equal "initialized", result.fetch("status")
    assert_path_exists result.fetch("database_path")
  end

  private

  def run_gem(*arguments)
    stdout, stderr, status = Open3.capture3({}, Gem.ruby, "-S", "gem", *arguments, chdir: @repo)
    {stdout:, stderr:, status:}
  end

  def run_installed(executable, home, *arguments)
    gem_path = ([File.join(@tmpdir, "gems")] + Gem.path).uniq.join(File::PATH_SEPARATOR)
    env = {
      "HOME" => home, "PATH" => ENV.fetch("PATH"), "LANG" => "C", "LC_ALL" => "C",
      "GEM_HOME" => File.join(@tmpdir, "gems"), "GEM_PATH" => gem_path,
      "RUBYOPT" => nil, "BUNDLE_GEMFILE" => nil, "BUNDLE_BIN_PATH" => nil
    }
    stdout, stderr, status = Open3.capture3(env, executable, *arguments, unsetenv_others: true)
    {stdout:, stderr:, status:}
  end
end
