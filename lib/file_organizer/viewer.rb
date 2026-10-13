# frozen_string_literal: true

require "rbconfig"

module FileOrganizer
  # Opens files with the OS default application, or previews text files
  # directly in the terminal.
  module Viewer
    PREVIEW_BYTES = 8192
    PREVIEW_LINES = 40

    # cmd.exe re-parses the command line it is handed, so a path containing
    # any of these cannot be passed through "start" safely at all. Such a
    # path is refused rather than quoted and hoped for.
    WINDOWS_UNSAFE = /["%&<>^|]/.freeze

    module_function

    # Launches the platform opener with an argument vector — the path is
    # never interpolated into a shell command, so file names containing
    # shell metacharacters cannot inject commands. Returns true on success,
    # false if no opener exists or it failed.
    def open_with_default_app(path)
      command = opener_command(File.expand_path(path))
      return false if command.nil?

      !!system(*command)
    end

    def opener_command(absolute_path)
      case RbConfig::CONFIG["host_os"]
      when /darwin/i then ["open", absolute_path]
      when /linux|bsd|solaris/i then ["xdg-open", absolute_path]
      when /mswin|mingw|cygwin/i then windows_command(absolute_path)
      end
    end

    def windows_command(absolute_path)
      return nil if absolute_path.match?(WINDOWS_UNSAFE)

      ["cmd", "/c", "start", "", absolute_path]
    end

    # Returns [lines, truncated?]. Lines are already sanitized for display.
    def text_preview(path)
      size = File.size(path)
      data = SafeFile.read(path, PREVIEW_BYTES).to_s
      text = data.force_encoding(Encoding::UTF_8).scrub("?").gsub("\t", "    ")
      all_lines = text.lines
      lines = all_lines.first(PREVIEW_LINES).map { |line| Console.safe(line.chomp) }
      truncated = size > data.bytesize || all_lines.size > PREVIEW_LINES
      [lines, truncated]
    rescue SystemCallError, IOError => e
      [["(could not read file: #{e.message})"], false]
    end
  end
end
