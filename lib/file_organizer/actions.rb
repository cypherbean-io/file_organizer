# frozen_string_literal: true

module FileOrganizer
  # The interactive half of the file operations: prompts, confirmations and
  # terminal-safe reporting. All validation and every filesystem call lives in
  # Operations, which the GUI shares.
  #
  # Return convention: each action returns the file's current path after the
  # operation, or nil when the file no longer exists at any path we track
  # (deleted, or moved away).
  module Actions
    module_function

    def rename(path)
      new_name = Console.ask("New file name (blank to cancel):")
      return path if new_name.nil? || new_name.empty?

      result = Operations.rename(path, new_name)
      report(result, cancelled: "rename cancelled")
      result.path
    end

    def delete(path)
      label = Console.safe(File.basename(path))
      return path unless Console.confirm?("Permanently delete #{label}?")

      result = Operations.delete(path)
      report(result)
      result.path
    end

    def copy(path)
      transfer(path, :copy)
    end

    def move(path)
      transfer(path, :move)
    end

    def transfer(path, operation)
      input = Console.ask("Destination directory (blank to cancel):")
      return path if input.nil? || input.empty?

      result = Operations.transfer(path, input, operation)
      if result.conflict?
        return path unless Console.confirm?("#{Console.safe(result.message)}. Overwrite?")

        result = Operations.transfer(path, input, operation, overwrite: true)
      end
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
