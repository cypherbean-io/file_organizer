# frozen_string_literal: true

require "optparse"
require "digest"

module FileOrganizer
  # Interactive command-line interface: walks the files of a directory one
  # by one, shows their details, and offers open/view, rename, copy, move
  # and delete actions.
  class CLI
    MODES = %i[general photo audio].freeze

    MENU_KEYS = {
      "o" => :open, "v" => :view, "r" => :rename, "c" => :copy,
      "m" => :move, "d" => :delete, "h" => :hash, "n" => :next, "q" => :quit
    }.freeze

    def initialize(argv)
      @mode = :general
      @directory_arg = parse_options(argv)
    end

    def run
      directory = resolve_directory
      return if directory.nil?

      files = scan(directory)
      if files.empty?
        Console.say("No #{@mode == :general ? "" : "#{@mode} "}files found in #{Console.safe(directory)}.")
        return
      end

      Console.say("#{files.size} file(s) to review in #{Console.safe(directory)} — #{@mode} mode.")
      catch(:quit) do
        files.each_with_index { |info, i| process_file(info, i + 1, files.size) }
        Console.say
        Console.say("All files reviewed.")
      end
    rescue Interrupt
      Console.say("\nStopped.")
    end

    private

    def parse_options(argv)
      rest = option_parser.parse(argv)
      abort("Too many arguments.\n#{option_parser}") if rest.size > 1
      rest.first
    rescue OptionParser::ParseError => e
      abort("#{e.message}\n#{option_parser}")
    end

    def option_parser
      @option_parser ||= OptionParser.new do |opts|
        opts.banner = "Usage: file_organizer [options] [DIRECTORY]"
        opts.on("-m", "--mode MODE", MODES.map(&:to_s),
                "Mode: general (default), photo, audio") { |m| @mode = m.to_sym }
        opts.on("-h", "--help", "Show this help") do
          puts opts
          exit
        end
        opts.on("--version", "Show version") do
          puts VERSION
          exit
        end
      end
    end

    def resolve_directory
      if @directory_arg
        directory = File.expand_path(@directory_arg)
        error = directory_error(directory)
        abort("file_organizer: #{error}") if error
        return directory
      end

      loop do
        input = Console.ask("Directory to organize (blank to quit):")
        return nil if input.nil? || input.empty?

        directory = File.expand_path(input)
        error = directory_error(directory)
        return directory if error.nil?

        Console.say("  #{error}")
      end
    end

    def directory_error(directory)
      return "does not exist: #{Console.safe(directory)}" unless File.exist?(directory)
      return "not a directory: #{Console.safe(directory)}" unless File.directory?(directory)
      return "directory is not readable: #{Console.safe(directory)}" unless File.readable?(directory)

      nil
    end

    # Regular files and symlinks only — subdirectories are never touched.
    def scan(directory)
      Dir.children(directory).sort_by(&:downcase).filter_map do |name|
        path = File.join(directory, name)
        next unless File.symlink?(path) || File.file?(path)

        info = FileInfo.new(path)
        info if include_in_mode?(info)
      rescue SystemCallError
        nil
      end
    end

    def include_in_mode?(info)
      case @mode
      when :photo then info.category == :photo
      when :audio then info.category == :audio
      else true
      end
    end

    def process_file(info, index, total)
      unless File.exist?(info.path) || File.symlink?(info.path)
        Console.say("Skipping #{Console.safe(info.name)} — it no longer exists.")
        return
      end

      Console.say
      Console.rule("File #{index} of #{total}")
      present(info)

      loop do
        choice = Console.ask(menu_prompt(info))
        throw :quit if choice.nil?

        case normalize(choice)
        when :open then open_file(info)
        when :view then view_file(info)
        when :rename then info = rename_file(info)
        when :copy then copy_file(info)
        when :move then return if move_file(info)
        when :delete then return if Actions.delete(info.path).nil?
        when :hash then show_checksum(info)
        when :next then return
        when :quit then throw :quit
        else Console.say("  Unrecognized option.")
        end
      end
    end

    def present(info)
      info.rows.each { |label, value| Console.field(label, value) }
      return unless info.regular?

      case @mode
      when :photo
        section("Photo metadata", Metadata::Photo.extract(info.path, info.detection.format))
      when :audio
        section("Audio metadata", Metadata::Audio.extract(info.path, info.detection.format))
      end
    end

    def section(title, fields)
      Console.say
      Console.say("  #{title}:")
      if fields.empty?
        Console.say("    (none found)")
      else
        fields.each { |label, value| Console.field(label, Console.safe(value.to_s), indent: 4) }
      end
    end

    def menu_prompt(info)
      parts = []
      parts << "[o]pen" if openable?(info)
      parts << "[v]iew" if viewable?(info)
      parts << "[r]ename"
      parts.push("[c]opy", "[m]ove") if info.regular?
      parts << "[d]elete"
      parts << "[h]ash" if info.regular?
      parts.push("[n]ext", "[q]uit")
      "\n  #{parts.join('  ')}\n  Choice [n]:"
    end

    def normalize(input)
      return :next if input.empty?

      MENU_KEYS[input[0].downcase]
    end

    def openable?(info)
      info.regular? && !info.executable_bit? && info.category != :executable
    end

    def viewable?(info)
      info.regular? && info.detection&.textual?
    end

    def open_file(info)
      unless openable?(info)
        Console.say("  Opening is disabled for this file (executable content or not a regular file).")
        return
      end
      if Viewer.open_with_default_app(info.path)
        Console.say("  Opened with the system default application.")
      else
        Console.say("  Could not open the file (no system opener available).")
      end
    end

    def view_file(info)
      unless viewable?(info)
        Console.say("  In-terminal preview is only available for text-based files; use [o]pen instead.")
        return
      end
      lines, truncated = Viewer.text_preview(info.path)
      Console.say
      if lines.empty?
        Console.say("  (file is empty)")
      else
        lines.each { |line| Console.say("  │ #{line}") }
        Console.say("  │ … (preview truncated)") if truncated
      end
      Console.say
    end

    def rename_file(info)
      new_path = Actions.rename(info.path)
      new_path == info.path ? info : FileInfo.new(new_path)
    end

    def copy_file(info)
      if info.regular?
        Actions.copy(info.path)
      else
        Console.say("  Only regular files can be copied.")
      end
    end

    # Returns true when the file was moved away (advance to the next file).
    def move_file(info)
      unless info.regular?
        Console.say("  Only regular files can be moved.")
        return false
      end
      Actions.move(info.path).nil?
    end

    def show_checksum(info)
      unless info.regular?
        Console.say("  Checksums are only available for regular files.")
        return
      end
      Console.say("  Computing SHA-256 (may take a moment for large files)…") if info.size > 50 * 1024 * 1024
      Console.field("SHA-256", Digest::SHA256.file(info.path).hexdigest)
    rescue SystemCallError => e
      Console.say("  Could not compute checksum: #{e.message}")
    end
  end
end
