# frozen_string_literal: true

module FileOrganizer
  # Terminal I/O helpers.
  #
  # Any string whose content comes from the filesystem or from file contents
  # (file names, metadata tags, text previews) is untrusted and must pass
  # through +safe+ before being printed, so that embedded control characters
  # cannot rewrite what the terminal shows.
  module Console
    WIDTH = 72

    # Characters that can misrepresent a string on screen:
    #   Cc  control characters (C0, DEL, C1) — including ESC, which starts a
    #       terminal escape sequence
    #   Cf  format characters — including U+202E RIGHT-TO-LEFT OVERRIDE and
    #       friends, which are what turns "invoice<RLO>gnp.exe" into an
    #       innocent-looking "invoice.png" on screen
    #   U+2028/U+2029  line and paragraph separators, which some terminals
    #       and pagers break lines on
    DISPLAY_UNSAFE = /[\p{Cc}\p{Cf}\u2028\u2029]/.freeze

    module_function

    # Renders an untrusted string safely: forces valid UTF-8 and replaces
    # every display-unsafe character with a visible escape.
    def safe(value)
      value.to_s.dup.force_encoding(Encoding::UTF_8).scrub("?")
           .gsub(DISPLAY_UNSAFE) { |char| escape(char) }
    end

    def escape(char)
      ordinal = char.ord
      ordinal <= 0xFF ? format("\\x%02X", ordinal) : format("\\u{%04X}", ordinal)
    end

    def say(text = "")
      $stdout.puts(text)
    end

    # Output is line-buffered on a terminal but block-buffered when it is
    # redirected, so anything the user has to act on is flushed explicitly.
    def flush
      $stdout.flush
    end

    def field(label, value, indent: 2)
      say(format("%s%-22s %s", " " * indent, "#{label}:", value))
    end

    def rule(title)
      line = "── #{title} "
      say(line + ("─" * [WIDTH - line.length, 0].max))
    end

    # Prompts and returns the stripped answer, or nil on end-of-input.
    def ask(prompt)
      $stdout.print("#{prompt} ")
      $stdout.flush
      $stdin.gets&.strip
    end

    # Irreversible operations — deleting, or overwriting something that is
    # already there — require the full word "yes". A stray keypress, a bare
    # Enter, or end-of-input can never confirm one.
    def confirm_exactly_yes?(prompt)
      ask("#{prompt} Type 'yes' to confirm:") == "yes"
    end

    # Every other change to a file still has to be agreed to, but takes a
    # y/N answer. Anything else — including Enter and end-of-input — is "no".
    def confirm?(prompt)
      %w[y yes].include?(ask("#{prompt} [y/N]:").to_s.downcase)
    end
  end
end
