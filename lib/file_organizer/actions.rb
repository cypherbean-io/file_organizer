# frozen_string_literal: true

module FileOrganizer
  # The interactive half of the file operations: prompts, confirmations and
  # terminal-safe reporting. All validation and every filesystem call lives in
  # Operations, which the GUI shares. Every change is confirmed before it
  # happens, and replacing something that is already there takes the whole
  # word "yes".
  #
  # Return convention: each action returns the file's current path after the
  # operation, or nil when the file no longer exists at any path we track
  # (deleted, or moved away). With +dry_run+ nothing is written and the
  # unchanged path always comes back.
  module Actions
    module_function

    def rename(path, dry_run: false)
      new_name = Console.ask("New file name (blank to cancel):")
      return path if new_name.nil? || new_name.empty?

      check = Operations.check_rename(path, new_name)
      unless check.ready?
        report(check, cancelled: "rename cancelled")
        return path
      end

      old_name = Console.safe(File.basename(path))
      return path unless Console.confirm?("Rename #{old_name} to #{Console.safe(new_name)}?")

      finish(Operations.rename(path, new_name, dry_run: dry_run))
    end

    def delete(path, dry_run: false)
      label = Console.safe(File.basename(path))
      return path unless Console.confirm_exactly_yes?("Permanently delete #{label}?")

      finish(Operations.delete(path, dry_run: dry_run))
    end

    def copy(path, dry_run: false)
      transfer(path, :copy, dry_run: dry_run)
    end

    def move(path, dry_run: false)
      transfer(path, :move, dry_run: dry_run)
    end

    # Kept for callers that validate a name before asking for anything else.
    def valid_filename?(name)
      Operations.valid_filename?(name)
    end

    def transfer(path, operation, dry_run: false)
      input = Console.ask("Destination directory (blank to cancel):")
      return path if input.nil? || input.empty?

      check = Operations.check_transfer(path, input)
      return finish(check) unless check.ready? || check.conflict?
      return path unless confirm_transfer(path, check, operation)

      finish(Operations.transfer(path, input, operation, overwrite: check.conflict?, dry_run: dry_run))
    end

    # A transfer onto a free name takes a y/N; replacing a file that is
    # already there is irreversible and takes the whole word "yes".
    def confirm_transfer(path, check, operation)
      name = Console.safe(File.basename(path))
      if check.conflict?
        Console.confirm_exactly_yes?("#{Console.safe(check.message)}. Overwrite it?")
      else
        destination = Console.safe(File.dirname(check.target))
        Console.confirm?("#{operation.capitalize} #{name} to #{destination}?")
      end
    end

    def finish(result)
      report(result)
      result.path
    end

    # Messages can contain file names and errno text, so they are sanitized
    # before they reach the terminal.
    def report(result, cancelled: nil)
      message = Console.safe(result.message)
      message = "#{message} — #{cancelled}." if result.conflict? && cancelled
      Console.say("  #{message}")
    end
  end
end
