# frozen_string_literal: true

require_relative "../../test_helper"

class CyborgBootstrapSafeFilesystemTest < Minitest::Test
  def setup
    @home = Dir.mktmpdir("cyborg-safe-filesystem")
    @outside = Dir.mktmpdir("cyborg-safe-filesystem-outside")
    @filesystem = Cyborg::Bootstrap::SafeFilesystem.new
  end

  def teardown
    FileUtils.remove_entry(@home)
    FileUtils.remove_entry(@outside)
  end

  def test_install_is_atomic_private_and_never_overwrites
    target = File.join(@home, ".config", "cyborg", "config.toml")

    assert_equal :created, @filesystem.install(path: target, bytes: "first")
    assert_equal 0o600, File.stat(target).mode & 0o777
    assert_equal :existing, @filesystem.install(path: target, bytes: "second")
    assert_equal "first", File.binread(target)
  end

  def test_install_rejects_symlinked_parent_and_final_path
    File.symlink(@outside, File.join(@home, ".config"))
    error = assert_raises(Cyborg::InvalidConfiguration) do
      @filesystem.install(path: File.join(@home, ".config", "cyborg", "config.toml"), bytes: "safe")
    end
    assert_equal "config.unsafe_path", error.code
    refute File.exist?(File.join(@outside, "cyborg", "config.toml"))

    target = File.join(@home, "symlinked")
    File.symlink(File.join(@outside, "target"), target)
    error = assert_raises(Cyborg::InvalidConfiguration) do
      @filesystem.install(path: target, bytes: "safe")
    end
    assert_equal "config.unsafe_path", error.code
  end

  def test_install_remains_anchored_when_checked_parent_is_swapped
    outside_target = File.join(@outside, "cyborg", "config.toml")
    FileUtils.mkdir_p(File.dirname(outside_target))
    File.chmod(0o700, File.join(@outside, "cyborg"))
    File.binwrite(outside_target, "outside")
    moved_parent = File.join(@home, ".config-moved")
    target = File.join(@home, ".config", "cyborg", "config.toml")
    swapped = false
    filesystem = Cyborg::Bootstrap::SafeFilesystem.new(before_publish: lambda {
      File.rename(File.join(@home, ".config"), moved_parent)
      File.symlink(@outside, File.join(@home, ".config"))
      swapped = true
    })

    assert_equal :created, filesystem.install(path: target, bytes: "safe")
    assert swapped
    assert_equal "outside", File.binread(outside_target)
    assert_equal "safe", File.binread(File.join(moved_parent, "cyborg", "config.toml"))
  ensure
    symlink = File.join(@home, ".config")
    File.unlink(symlink) if File.symlink?(symlink)
    FileUtils.remove_entry(moved_parent) if moved_parent && File.exist?(moved_parent)
  end

  def test_ensure_directory_creates_private_leaf_and_rejects_unsafe_existing_leaf
    path = File.join(@home, ".config", "cyborg")
    assert_equal :created, @filesystem.ensure_directory(path: path)
    assert_equal 0o700, File.stat(path).mode & 0o777
    assert_equal :existing, @filesystem.ensure_directory(path: path)

    File.chmod(0o755, path)
    error = assert_raises(Cyborg::InvalidConfiguration) { @filesystem.ensure_directory(path: path) }
    assert_equal "config.unsafe_path", error.code
  end

  def test_install_surfaces_temp_cleanup_failure_as_persistence_error
    target = File.join(@home, "config.toml")
    libc = Cyborg::Bootstrap::SafeFilesystem::LibC
    original = libc.method(:unlinkat)
    libc.define_singleton_method(:unlinkat) { |_parent, _name, _flags| -1 }
    error = assert_raises(Cyborg::InvalidConfiguration) do
      @filesystem.install(path: target, bytes: "safe")
    end
    assert_equal "config.persistence", error.code
  ensure
    libc.define_singleton_method(:unlinkat, original) if libc && original
  end
end
