# frozen_string_literal: true

module FileOrganizer
  # File operations. Every input is validated, every change is confirmed
  # before it happens, nothing is overwritten silently, and no operation
  # ever writes through a symbolic link.
  #
  # Return convention: each action returns the file's current path after the
  # operation, or nil when the file no longer exists at any path we track
  # (deleted, or moved away). With +dry_run+ nothing is written and the
  # unchanged path always comes back.
  module Actions
    FILENAME_MAX_BYTES = 255

    module_function

    def rename(path, dry_run: false)
      new_name = Console.ask("New file name (blank to cancel):")
      return path if new_name.nil? || new_name.empty?

      unless valid_filename?(new_name)
        Console.say("  Invalid name: no path separators, control characters, '.' or '..'.")
        return path
      end

      old_name = Console.safe(File.basename(path))
      safe_name = Console.safe(new_name)
      target = File.join(File.dirname(path), new_name)

      # On a case-insensitive filesystem "notes.txt" and "Notes.TXT" are the
      # same file, so a case-only rename is a rename, not a collision.
      same_file = File.identical?(path, target)
      if !same_file && exists?(target)
        Console.say("  A file named #{safe_name} already exists — rename cancelled.")
        return path
      end

      return path unless Console.confirm?("Rename #{old_name} to #{safe_name}?")
      return preview(path, "rename #{old_name} to #{safe_name}") if dry_run

      rename_without_clobber(path, target, same_file)
      Console.say("  Renamed to #{safe_name}.")
      target
    rescue SystemCallError => e
      Console.say("  Rename failed: #{e.message}")
      path
    end

    def delete(path, dry_run: false)
      label = Console.safe(File.basename(path))
      return path unless Console.confirm_exactly_yes?("Permanently delete #{label}?")
      return preview(path, "delete #{label}") if dry_run

      File.unlink(path) # removes a symlink itself, never its target
      Console.say("  Deleted #{label}.")
      nil
    rescue SystemCallError => e
      Console.say("  Delete failed: #{e.message}")
      path
    end

    def copy(path, dry_run: false)
      transfer(path, :copy, dry_run: dry_run)
    end

    def move(path, dry_run: false)
      transfer(path, :move, dry_run: dry_run)
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

    def transfer(path, operation, dry_run: false)
      input = Console.ask("Destination directory (blank to cancel):")
      return path if input.nil? || input.empty?

      destination = File.expand_path(input)
      error = destination_error(destination)
      return complain(path, error) if error

      target = File.join(destination, File.basename(path))
      if File.identical?(path, target)
        Console.say("  Source and destination are the same file — nothing to do.")
        return path
      end

      error = target_error(target)
      return complain(path, error) if error

      return path unless confirm_transfer(path, destination, target, operation)
      return preview(path, "#{operation} #{Console.safe(File.basename(path))} to #{Console.safe(target)}") if dry_run

      perform(path, target, operation)
    rescue SystemCallError, IOError, ArgumentError => e
      Console.say("  #{operation.capitalize} failed: #{e.message}")
      path
    end

    def confirm_transfer(path, destination, target, operation)
      name = Console.safe(File.basename(path))
      if File.exist?(target)
        Console.confirm_exactly_yes?("#{name} already exists in #{Console.safe(destination)}. Overwrite it?")
      else
        Console.confirm?("#{operation.capitalize} #{name} to #{Console.safe(destination)}?")
      end
    end

    def perform(path, target, operation)
      if operation == :copy
        copy_bytes(path, target)
        Console.say("  Copied to #{Console.safe(target)}.")
        path
      else
        move_bytes(path, target)
        Console.say("  Moved to #{Console.safe(target)}.")
        nil
      end
    end

    def destination_error(dir)
      return "Does not exist: #{Console.safe(dir)}" unless File.exist?(dir)
      return "Not a directory: #{Console.safe(dir)}" unless File.directory?(dir)
      return "Directory is not writable: #{Console.safe(dir)}" unless File.writable?(dir)

      nil
    end

    # A destination name that is not a plain file is refused outright.
    # Writing through a symbolic link would put the data wherever the link
    # points — outside the directory the user picked, and under a name the
    # confirmation prompt never mentioned. A directory at that name would
    # quietly turn "replace that file" into "put it inside".
    def target_error(target)
      name = Console.safe(File.basename(target))
      if File.symlink?(target)
        return "#{name} in that directory is a symbolic link — refusing to write through it."
      end
      return "#{name} in that directory is a directory, not a file." if File.directory?(target)

      nil
    end

    # File.rename replaces an existing target silently, so for a regular file
    # the new name is staked out with link(2) first — that fails if the name
    # was taken in the moment since the check above — and only then is the old
    # name dropped. Where hard links are unavailable (another filesystem, a
    # symlink, a case-only rename on a case-insensitive volume) it falls back
    # to the plain rename.
    def rename_without_clobber(path, target, same_file)
      return File.rename(path, target) if same_file || !File.lstat(path).file?

      begin
        File.link(path, target)
      rescue Errno::EEXIST
        raise
      rescue SystemCallError
        return File.rename(path, target)
      end
      File.unlink(path)
    end

    # Opens the destination explicitly with O_NOFOLLOW so that a symbolic
    # link appearing at the target after +target_error+ ran still cannot
    # redirect the copy out of the chosen directory. Permission bits and
    # timestamps are carried over; set-user-ID and set-group-ID bits are not.
    def copy_bytes(source, target)
      stat = File.lstat(source)
      flags = File::WRONLY | File::CREAT | File::TRUNC | SafeFile::NOFOLLOW
      File.open(target, flags, 0o600) do |output|
        output.binmode
        SafeFile.open(source) { |input| IO.copy_stream(input, output) }
      end
      File.chmod(stat.mode & 0o777, target)
      File.utime(stat.atime, stat.mtime, target)
    end

    # rename(2) replaces the destination name itself, so it cannot write
    # through a link either. Across filesystems it falls back to the
    # O_NOFOLLOW copy, and the source is only removed once that succeeded.
    def move_bytes(source, target)
      File.rename(source, target)
    rescue Errno::EXDEV
      copy_bytes(source, target)
      File.unlink(source)
    end

    def exists?(path)
      File.exist?(path) || File.symlink?(path)
    end

    def preview(path, description)
      Console.say("  [dry run] would #{description}.")
      path
    end

    def complain(path, message)
      Console.say("  #{message}")
      path
    end
  end
end
