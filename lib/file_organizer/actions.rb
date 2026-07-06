# frozen_string_literal: true

require "fileutils"

module FileOrganizer
  # File operations. Every input is validated, nothing is overwritten
  # without explicit confirmation, and deletion requires typing "yes".
  #
  # Return convention: each action returns the file's current path after the
  # operation, or nil when the file no longer exists at any path we track
  # (deleted, or moved away).
  module Actions
    FILENAME_MAX_BYTES = 255

    module_function

    def rename(path)
      new_name = Console.ask("New file name (blank to cancel):")
      return path if new_name.nil? || new_name.empty?

      unless valid_filename?(new_name)
        Console.say("  Invalid name: no path separators, control characters, '.' or '..'.")
        return path
      end

      target = File.join(File.dirname(path), new_name)
      if File.exist?(target) || File.symlink?(target)
        Console.say("  A file named #{Console.safe(new_name)} already exists — rename cancelled.")
        return path
      end

      File.rename(path, target)
      Console.say("  Renamed to #{Console.safe(new_name)}.")
      target
    rescue SystemCallError => e
      Console.say("  Rename failed: #{e.message}")
      path
    end

    def delete(path)
      label = Console.safe(File.basename(path))
      return path unless Console.confirm?("Permanently delete #{label}?")

      File.unlink(path) # removes a symlink itself, never its target
      Console.say("  Deleted #{label}.")
      nil
    rescue SystemCallError => e
      Console.say("  Delete failed: #{e.message}")
      path
    end

    def copy(path)
      transfer(path, :copy)
    end

    def move(path)
      transfer(path, :move)
    end

    # A file name is only ever a single path component: rejecting separators
    # and ".." makes path traversal via a crafted name impossible.
    def valid_filename?(name)
      return false if name.bytesize > FILENAME_MAX_BYTES
      return false if [".", ".."].include?(name)
      return false if name.include?("/") || name.include?("\\") || name.include?("\0")
      return false if name.match?(/\p{Cc}/)

      true
    end

    def transfer(path, operation)
      input = Console.ask("Destination directory (blank to cancel):")
      return path if input.nil? || input.empty?

      destination_dir = File.expand_path(input)
      error = destination_error(destination_dir)
      if error
        Console.say("  #{error}")
        return path
      end

      target = File.join(destination_dir, File.basename(path))
      if File.identical?(path, target)
        Console.say("  Source and destination are the same file — nothing to do.")
        return path
      end
      if File.exist?(target) || File.symlink?(target)
        return path unless Console.confirm?("#{Console.safe(File.basename(path))} already exists there. Overwrite?")
      end

      if operation == :copy
        FileUtils.cp(path, target, preserve: true)
        Console.say("  Copied to #{Console.safe(target)}.")
        path
      else
        FileUtils.mv(path, target)
        Console.say("  Moved to #{Console.safe(target)}.")
        nil
      end
    rescue SystemCallError, ArgumentError => e
      Console.say("  #{operation.capitalize} failed: #{e.message}")
      path
    end

    def destination_error(dir)
      return "Does not exist: #{Console.safe(dir)}" unless File.exist?(dir)
      return "Not a directory: #{Console.safe(dir)}" unless File.directory?(dir)
      return "Directory is not writable: #{Console.safe(dir)}" unless File.writable?(dir)

      nil
    end
  end
end
