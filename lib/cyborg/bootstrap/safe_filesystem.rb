# frozen_string_literal: true

require "fiddle/import"
require "securerandom"

module Cyborg
  module Bootstrap
    # The only pathname operations in this class are used to split an absolute
    # name into components. All accesses to bootstrap targets happen relative
    # to retained directory descriptors, with O_NOFOLLOW on every lookup.
    class SafeFilesystem
      FileIdentity = Data.define(:dev, :ino, :mode, :uid)
      DirectoryOpen = Data.define(:fd, :created)

      module LibC
        extend Fiddle::Importer

        dlload Fiddle::Handle::DEFAULT
        extern "int open(const char *, int, int)"
        extern "int openat(int, const char *, int, int)"
        extern "int mkdirat(int, const char *, int)"
        extern "int linkat(int, const char *, int, const char *, int)"
        extern "int unlinkat(int, const char *, int)"
        extern "int fchmod(int, int)"
        extern "int fsync(int)"
        extern "int close(int)"
      end

      O_RDONLY = File::RDONLY
      O_WRONLY = File::WRONLY
      O_CREAT = File::CREAT
      O_EXCL = File::EXCL
      O_NONBLOCK = File.const_defined?(:NONBLOCK) ? File::NONBLOCK : 0x0004
      O_NOFOLLOW = File.const_defined?(:NOFOLLOW) ? File::NOFOLLOW : 0x100
      O_DIRECTORY = if RUBY_PLATFORM.include?("darwin") || RUBY_PLATFORM.include?("freebsd")
        0x00100000
      else
        0x00010000
      end
      attr_accessor :before_publish

      def initialize(before_publish: nil)
        @before_publish = before_publish
      end

      def install(path:, bytes:, mode: 0o600)
        _absolute, components = split_path(path)
        parent_components = components[0...-1]
        final_name = components[-1]
        raise InvalidConfiguration.new("config.unsafe_path") if final_name.nil? || final_name.empty?

        with_parent_directory(parent_components) do |parent_fd|
          existing_fd = LibC.openat(parent_fd, final_name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW, 0)
          if existing_fd >= 0
            begin
              require_regular!(existing_fd)
              return :existing
            ensure
              close_fd(existing_fd)
            end
          end
          existing_errno = errno
          unless [Errno::ENOENT::Errno].include?(existing_errno)
            raise_unsafe_or_persistence(existing_errno)
          end

          temp_name = ".cyborg-bootstrap-#{SecureRandom.hex(12)}"
          temp_fd = LibC.openat(parent_fd, temp_name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode)
          raise_unsafe_or_persistence(errno) if temp_fd < 0
          begin
            write_bytes(temp_fd, bytes)
            fail_persistence!("config.persistence") unless LibC.fchmod(temp_fd, Integer(mode)) == 0
            fail_persistence!("config.persistence") unless LibC.fsync(temp_fd) == 0
            invoke_hook(@before_publish, parent_fd, temp_name, final_name)

            linked = LibC.linkat(parent_fd, temp_name, parent_fd, final_name, 0)
            if linked == 0
              :created
            else
              link_errno = errno
              if link_errno == Errno::EEXIST::Errno
                final_fd = LibC.openat(parent_fd, final_name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW, 0)
                raise_unsafe_or_persistence(errno) if final_fd < 0
                begin
                  require_regular!(final_fd)
                  :existing
                ensure
                  close_fd(final_fd)
                end
              else
                raise_unsafe_or_persistence(link_errno)
              end
            end
          ensure
            close_fd(temp_fd)
            LibC.unlinkat(parent_fd, temp_name, 0)
            fail_persistence!("config.persistence") unless LibC.fsync(parent_fd) == 0
          end
        end
      rescue InvalidConfiguration
        raise
      rescue SystemCallError => error
        raise InvalidConfiguration.new("config.persistence", error.message)
      end

      def ensure_directory(path:, mode: 0o700)
        _absolute, components = split_path(path)
        raise InvalidConfiguration.new("config.unsafe_path") if components.empty?

        with_directory_path(components, leaf_mode: Integer(mode))
      rescue InvalidConfiguration
        raise
      rescue SystemCallError => error
        raise InvalidConfiguration.new("config.persistence", error.message)
      end

      def regular_file_identity(path:)
        _absolute, components = split_path(path)
        final_name = components.pop
        raise InvalidConfiguration.new("config.unsafe_path") if final_name.nil? || final_name.empty?

        with_parent_directory(components) do |parent_fd|
          fd = LibC.openat(parent_fd, final_name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW, 0)
          raise InvalidConfiguration.new("config.unsafe_path") if fd < 0 && [Errno::ELOOP::Errno, Errno::ENOTDIR::Errno].include?(errno)
          raise_unsafe_or_persistence(errno) if fd < 0
          begin
            stat = io_stat(fd)
            raise InvalidConfiguration.new("config.unsafe_path") unless stat.file?

            FileIdentity.new(stat.dev, stat.ino, stat.mode, stat.uid)
          ensure
            close_fd(fd)
          end
        end
      rescue InvalidConfiguration
        raise
      rescue SystemCallError => error
        raise InvalidConfiguration.new("config.persistence", error.message)
      end

      private

      def split_path(path)
        value = path.to_s
        raise InvalidConfiguration.new("config.unsafe_path") unless value.start_with?("/")
        components = value.split("/")
        if components.include?(".") || components.include?("..")
          raise InvalidConfiguration.new("config.unsafe_path")
        end
        absolute = File.expand_path(value)
        # macOS exposes its writable temporary tree through the historical
        # /var symlink. Canonicalize that OS-owned alias before descriptor
        # traversal; user-controlled symlinks remain rejected by O_NOFOLLOW.
        absolute = absolute.sub(%r{\A/var(/|\z)}, "/private/var\\1") if RUBY_PLATFORM.include?("darwin")
        unless absolute.start_with?("/")
          raise InvalidConfiguration.new("config.unsafe_path")
        end
        normalized = absolute.split("/").reject(&:empty?)
        raise InvalidConfiguration.new("config.unsafe_path") if normalized.include?(".") || normalized.include?("..")

        [absolute, normalized]
      end

      def with_parent_directory(components)
        root_fd = LibC.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW, 0)
        raise_unsafe_or_persistence(errno) if root_fd < 0
        descriptors = [root_fd]
        begin
          current = root_fd
          components.each do |component|
            opened = open_or_create_directory(current, component)
            current = opened.fd
            descriptors << current
            # Existing parent directories are traversed under the ancestor
            # policy. Newly created bootstrap directories receive the stricter
            # private-leaf check; callers that require an existing leaf to be
            # private use ensure_directory explicitly before installing.
            verify_ancestor!(current, leaf: opened.created)
          end
          yield current
        ensure
          descriptors.reverse_each { |fd| close_fd(fd) }
        end
      end

      def with_directory_path(components, leaf_mode:)
        root_fd = LibC.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW, 0)
        raise_unsafe_or_persistence(errno) if root_fd < 0
        descriptors = [root_fd]
        begin
          current = root_fd
          created_any = false
          components.each_with_index do |component, index|
            leaf = index == components.length - 1
            opened = open_or_create_directory(current, component)
            current = opened.fd
            created_any ||= opened.created
            descriptors << current
            verify_ancestor!(current, leaf:, mode: leaf_mode, require_owner: leaf)
          end
          created_any ? :created : :existing
        ensure
          descriptors.reverse_each { |fd| close_fd(fd) }
        end
      end

      def open_or_create_directory(parent_fd, component)
        fd = LibC.openat(parent_fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW, 0)
        created = false
        if fd < 0
          open_errno = errno
          unless open_errno == Errno::ENOENT::Errno
            raise_unsafe_or_persistence(open_errno)
          end
          created = LibC.mkdirat(parent_fd, component, 0o700)
          if created < 0
            mkdir_errno = errno
            unless mkdir_errno == Errno::EEXIST::Errno
              raise_unsafe_or_persistence(mkdir_errno)
            end
          else
            created = true
          end
          fd = LibC.openat(parent_fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW, 0)
          raise_unsafe_or_persistence(errno) if fd < 0
        end
        stat = io_stat(fd)
        unless stat.directory?
          close_fd(fd)
          raise InvalidConfiguration.new("config.unsafe_path")
        end
        DirectoryOpen.new(fd, created == true)
      end

      def verify_ancestor!(fd, leaf:, mode: 0o700, require_owner: false)
        stat = io_stat(fd)
        raise InvalidConfiguration.new("config.unsafe_path") unless stat.directory?
        permissions = stat.mode & 0o7777
        if leaf
          if require_owner && stat.uid != Process.uid
            raise InvalidConfiguration.new("config.unsafe_path")
          end
          sticky_temporary = (permissions & 0o1000) != 0 && (permissions & 0o077) != 0
          if sticky_temporary && stat.uid != Process.uid
            return true
          end
          if stat.uid == Process.uid
            safe = if mode == 0o700
              (permissions & 0o077).zero? && (permissions & 0o700) == 0o700
            else
              # Legacy callers may validate an existing, user-owned
              # non-writable directory with a less restrictive requested
              # mode. Newly created directories remain 0700.
              (permissions & 0o022).zero?
            end
          else
            # System-owned ancestors such as /Users are allowed when they
            # cannot be modified by group or other users. A current-user
            # bootstrap leaf must satisfy the stricter private-directory
            # policy above.
            safe = (permissions & 0o022).zero?
          end
          unless safe
            raise InvalidConfiguration.new("config.unsafe_path")
          end
        elsif (permissions & 0o022) != 0 && (permissions & 0o1000) == 0
          raise InvalidConfiguration.new("config.unsafe_path")
        end
      end

      def io_stat(fd)
        IO.for_fd(fd, autoclose: false).stat
      rescue IOError, SystemCallError => error
        raise InvalidConfiguration.new("config.unsafe_path", error.message)
      end

      def require_regular!(fd)
        raise InvalidConfiguration.new("config.unsafe_path") unless io_stat(fd).file?
      end

      def write_bytes(fd, bytes)
        io = IO.for_fd(fd, autoclose: false)
        io.binmode
        string = bytes.to_s.b
        offset = 0
        while offset < string.bytesize
          written = io.write(string.byteslice(offset, string.bytesize - offset))
          raise InvalidConfiguration.new("config.persistence") unless written && written.positive?
          offset += written
        end
        io.flush
      rescue IOError, SystemCallError => error
        raise InvalidConfiguration.new("config.persistence", error.message)
      end

      def invoke_hook(hook, *arguments)
        return unless hook

        case hook.arity
        when 0 then hook.call
        when 1 then hook.call(arguments.first)
        when 2 then hook.call(*arguments.first(2))
        else hook.call(*arguments)
        end
      end

      def close_fd(fd)
        LibC.close(fd) if fd && fd >= 0
      rescue StandardError
        nil
      end

      def errno
        Fiddle.last_error
      end

      def raise_unsafe_or_persistence(number)
        if [Errno::ELOOP::Errno, Errno::ENOTDIR::Errno, Errno::EACCES::Errno, Errno::EPERM::Errno,
            Errno::EINVAL::Errno, Errno::EISDIR::Errno, Errno::EEXIST::Errno].include?(number)
          raise InvalidConfiguration.new("config.unsafe_path")
        end
        raise InvalidConfiguration.new("config.persistence")
      end

      def fail_persistence!(code)
        raise InvalidConfiguration.new(code)
      end
    end
  end
end
