# frozen_string_literal: true

module FileOrganizer
  # Terminal I/O helpers.
  #
  # Any string whose content comes from the filesystem or from file contents
  # (file names, metadata tags, text previews) is untrusted and must pass
  # through +safe+ before being printed, so that embedded control characters
  # cannot inject terminal escape sequences.
  module Console
    WIDTH = 72

    module_function

    # Renders an untrusted string safely: forces valid UTF-8 and replaces
    # control characters (Unicode category Cc, which covers C0, DEL and C1 —
    # including ESC) with visible hex escapes.
    def safe(value)
      value.to_s.dup.force_encoding(Encoding::UTF_8).scrub("?")
           .gsub(/\p{Cc}/) { |ch| format("\\x%02X", ch.ord) }
    end

    def say(text = "")
      $stdout.puts(text)
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

    # Destructive operations require the full word "yes" — a stray keypress
    # can never confirm one.
    def confirm?(prompt)
      ask("#{prompt} Type 'yes' to confirm:") == "yes"
    end
  end
end
