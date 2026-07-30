# frozen_string_literal: true

require "fileutils"

module FileOrganizer
  # The file operations themselves, with no user interaction: every input is
  # validated, nothing is overwritten unless the caller explicitly asks for
  # it, and the outcome is reported through a Result. Both front ends (the
  # interactive CLI and the GUI) go through this module, so the safety rules
  # live in exactly one place.
  #
  # Result#path follows the convention used throughout the program: the file's
  # current path after the operation, or nil when the file no longer exists at
  # any path we track (deleted, or moved away). Messages are returned raw —
  # each front end sanitizes them for its own medium.
  module Operations
    FILENAME_MAX_BYTES = 255

    # A file name that is not valid UTF-8 must not make the validation itself
    # raise, so the checks below are byte-wise. \p{Cc} covers C0, DEL and C1;
    # C0 and DEL are single bytes, C1 is this two-byte sequence in UTF-8.
    C1_BYTES = /\xC2[\x80-\x9F]/n

    Result = Struct.new(:status, :path, :message, keyword_init: true) do
      def ok?
        status == :ok
      end

      # The operation was refused because it would have destroyed something;
      # retry with overwrite: true to go ahead.
      def conflict?
        status == :conflict
      end

      def error?
        status == :error
      end
    end

    module_function

    def rename(path, new_name)
      unless valid_filename?(new_name)
        return failure(path, "Invalid name: no path separators, control characters, '.' or '..'.")
      end

      target = File.join(File.dirname(path), new_name)
      return conflict(path, "A file named #{new_name} already exists") if present?(target)

      File.rename(path, target)
      success(target, "Renamed to #{new_name}.")
    rescue SystemCallError => e
      failure(path, "Rename failed: #{e.message}")
    end

    def delete(path)
      File.unlink(path) # removes a symlink itself, never its target
      success(nil, "Deleted #{File.basename(path)}.")
    rescue SystemCallError => e
      failure(path, "Delete failed: #{e.message}")
    end

    def copy(path, destination, overwrite: false)
      transfer(path, destination, :copy, overwrite: overwrite)
    end

    def move(path, destination, overwrite: false)
      transfer(path, destination, :move, overwrite: overwrite)
    end

    def transfer(path, destination, operation, overwrite: false)
      destination_dir = File.expand_path(destination)
      error = destination_error(destination_dir)
      return failure(path, error) if error

      target = File.join(destination_dir, File.basename(path))
      if File.identical?(path, target)
        return success(path, "Source and destination are the same file — nothing to do.")
      end
      return conflict(path, "#{File.basename(path)} already exists there") if present?(target) && !overwrite

      if operation == :copy
        FileUtils.cp(path, target, preserve: true)
        success(path, "Copied to #{target}.")
      else
        FileUtils.mv(path, target)
        success(nil, "Moved to #{target}.")
      end
    rescue SystemCallError, ArgumentError => e
      failure(path, "#{operation.capitalize} failed: #{e.message}")
    end

    # A name the user asks us to create: a single path component, and free of
    # control characters, which have no business in a new file name.
    def valid_filename?(name)
      return false unless single_component?(name)
      return false if name.include?("/") || name.include?("\\")
      return false if name.each_byte.any? { |byte| byte < 0x20 || byte == 0x7F }
      return false if C1_BYTES.match?(name.b)

      true
    end

    # A name that already exists in a directory, which the filesystem allows to
    # contain almost anything. Rejecting the separators and ".." is what makes
    # path traversal through a crafted name impossible; a control character in
    # an existing name is only a display problem, and refusing to touch such a
    # file would mean refusing to help clean it up.
    def single_component?(name)
      return false unless name.is_a?(String)
      return false if name.empty? || name.bytesize > FILENAME_MAX_BYTES
      return false if [".", ".."].include?(name)
      return false if name.include?("\0")

      separators = [File::SEPARATOR, File::ALT_SEPARATOR].compact
      separators.none? { |separator| name.include?(separator) }
    end

    def destination_error(dir)
      error = Directory.error(dir, access: :write)
      error&.sub(/\A./, &:upcase)
    end

    def present?(path)
      File.exist?(path) || File.symlink?(path)
    end

    def success(path, message)
      Result.new(status: :ok, path: path, message: message)
    end

    def failure(path, message)
      Result.new(status: :error, path: path, message: message)
    end

    def conflict(path, message)
      Result.new(status: :conflict, path: path, message: message)
    end
  end
end
