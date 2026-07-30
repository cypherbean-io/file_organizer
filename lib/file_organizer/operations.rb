# frozen_string_literal: true

module FileOrganizer
  # The file operations themselves, with no user interaction: every input is
  # validated, nothing is overwritten unless the caller explicitly asks for
  # it, no operation ever writes through a symbolic link, and the outcome is
  # reported through a Result. Both front ends (the interactive CLI and the
  # GUI) go through this module, so the safety rules live in exactly one
  # place.
  #
  # Each change comes in two halves. +check_rename+ and +check_transfer+
  # validate a request without touching anything, so the terminal can ask
  # for confirmation in between; +rename+ and +transfer+ repeat that check
  # themselves before acting, so a caller that skips straight to them (the
  # GUI) gets exactly the same protection.
  #
  # Result#path follows the convention used throughout the program: the file's
  # current path after the operation, or nil when the file no longer exists at
  # any path we track (deleted, or moved away). With +dry_run+ nothing is
  # written and the unchanged path always comes back. Messages are returned
  # raw — each front end sanitizes them for its own medium.
  module Operations
    FILENAME_MAX_BYTES = 255

    # A file name that is not valid UTF-8 must not make the validation itself
    # raise, so the checks below are byte-wise. \p{Cc} covers C0, DEL and C1;
    # C0 and DEL are single bytes, C1 is this two-byte sequence in UTF-8.
    C1_BYTES = /\xC2[\x80-\x9F]/n

    # +target+ is where the file would go; +exists+ says whether something is
    # already there. Both are set on the :ready result of a check.
    Result = Struct.new(:status, :path, :message, :target, :exists, keyword_init: true) do
      def ok?
        status == :ok
      end

      # A check passed: the operation may go ahead once the user agrees.
      def ready?
        status == :ready
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

    # --- rename ---------------------------------------------------------------

    def check_rename(path, new_name)
      unless valid_filename?(new_name)
        return failure(path, "Invalid name: no path separators, control characters, '.' or '..'.")
      end

      target = File.join(File.dirname(path), new_name)
      # On a case-insensitive filesystem "notes.txt" and "Notes.TXT" are the
      # same file, so a case-only rename is a rename, not a collision.
      if !File.identical?(path, target) && present?(target)
        return conflict(path, "A file named #{new_name} already exists")
      end

      ready(path, target, exists: false)
    end

    def rename(path, new_name, dry_run: false)
      check = check_rename(path, new_name)
      return check unless check.ready?

      label = "#{File.basename(path)} to #{new_name}"
      return preview(path, "rename #{label}") if dry_run

      rename_without_clobber(path, check.target, File.identical?(path, check.target))
      success(check.target, "Renamed to #{new_name}.")
    rescue SystemCallError => e
      failure(path, "Rename failed: #{e.message}")
    end

    # --- delete ---------------------------------------------------------------

    def delete(path, dry_run: false)
      return preview(path, "delete #{File.basename(path)}") if dry_run

      File.unlink(path) # removes a symlink itself, never its target
      success(nil, "Deleted #{File.basename(path)}.")
    rescue SystemCallError => e
      failure(path, "Delete failed: #{e.message}")
    end

    # --- copy and move --------------------------------------------------------

    def copy(path, destination, overwrite: false, dry_run: false)
      transfer(path, destination, :copy, overwrite: overwrite, dry_run: dry_run)
    end

    def move(path, destination, overwrite: false, dry_run: false)
      transfer(path, destination, :move, overwrite: overwrite, dry_run: dry_run)
    end

    # A :ready result means the transfer may go ahead; :conflict means a file
    # is already at the target and only overwrite: true lets it be replaced;
    # :ok means there is nothing to do; :error says why it is refused.
    def check_transfer(path, destination, overwrite: false)
      return failure(path, "Only regular files can be copied or moved.") unless File.lstat(path).file?

      destination_dir = File.expand_path(destination)
      error = destination_error(destination_dir)
      return failure(path, error) if error

      target = File.join(destination_dir, File.basename(path))
      if File.identical?(path, target)
        return success(path, "Source and destination are the same file — nothing to do.")
      end

      error = target_error(target)
      return failure(path, error) if error

      exists = File.exist?(target)
      return conflict(path, "#{File.basename(path)} already exists in #{destination_dir}") if exists && !overwrite

      ready(path, target, exists: exists)
    rescue SystemCallError => e
      failure(path, "Cannot use that file: #{e.message}")
    rescue ArgumentError => e # File.expand_path on "~nosuchuser"
      failure(path, e.message)
    end

    def transfer(path, destination, operation, overwrite: false, dry_run: false)
      check = check_transfer(path, destination, overwrite: overwrite)
      return check unless check.ready?
      return preview(path, "#{operation} #{File.basename(path)} to #{check.target}") if dry_run

      if operation == :copy
        copy_bytes(path, check.target)
        success(path, "Copied to #{check.target}.")
      else
        move_bytes(path, check.target)
        success(nil, "Moved to #{check.target}.")
      end
    rescue SystemCallError, IOError, ArgumentError => e
      failure(path, "#{operation.capitalize} failed: #{e.message}")
    end

    # --- names ----------------------------------------------------------------

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

    # --- checks ---------------------------------------------------------------

    def destination_error(dir)
      error = Directory.error(dir, access: :write)
      error&.sub(/\A./, &:upcase)
    end

    # A destination name that is not a plain file is refused outright.
    # Writing through a symbolic link would put the data wherever the link
    # points — outside the directory the user picked, and under a name the
    # confirmation never mentioned. A directory at that name would quietly
    # turn "replace that file" into "put it inside".
    def target_error(target)
      name = File.basename(target)
      if File.symlink?(target)
        return "#{name} in that directory is a symbolic link — refusing to write through it."
      end
      return "#{name} in that directory is a directory, not a file." if File.directory?(target)

      nil
    end

    def present?(path)
      File.exist?(path) || File.symlink?(path)
    end

    # --- filesystem -----------------------------------------------------------

    # File.rename replaces an existing target silently, so for a regular file
    # the new name is staked out with link(2) first — that fails if the name
    # was taken in the moment since the check — and only then is the old name
    # dropped. Where hard links are unavailable (another filesystem, a
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

    # --- results --------------------------------------------------------------

    def ready(path, target, exists:)
      Result.new(status: :ready, path: path, target: target, exists: exists)
    end

    def preview(path, description)
      success(path, "[dry run] would #{description}.")
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
