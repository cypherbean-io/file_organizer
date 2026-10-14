# frozen_string_literal: true

require "optparse"

module FileOrganizer
  # Interactive command-line interface: walks the files of a directory one
  # by one, shows their details, and offers open/view, rename, copy, move
  # and delete actions.
  #
  # It also parses the options for, and hands over to, the graphical
  # interface (see FileOrganizer::Gui), which offers the same actions in a
  # page instead of a prompt.
  class CLI
    MODES = %i[general photo audio].freeze

    # Menu input is matched in full, never by first letter: typing a word
    # like "done" or "move it later" must not fire an action the user never
    # asked for.
    MENU_KEYS = {
      "o" => :open, "open" => :open,
      "v" => :view, "view" => :view,
      "r" => :rename, "rename" => :rename,
      "c" => :copy, "copy" => :copy,
      "m" => :move, "move" => :move,
      "d" => :delete, "delete" => :delete,
      "h" => :hash, "hash" => :hash,
      "n" => :next, "next" => :next,
      "q" => :quit, "quit" => :quit
    }.freeze

    # Actions that change something on disk — or, for :open, hand the file to
    # another program that might. Read-only mode refuses all of them.
    MUTATING_ACTIONS = %i[open rename copy move delete].freeze

    def initialize(argv)
      @mode = :general
      @read_only = false
      @dry_run = false
      @gui = false
      @port = 0
      @browser = true
      @directory_arg = parse_options(argv)
    end

    def run
      return run_gui if @gui

      directory = resolve_directory
      return if directory.nil?
      return unless confirm_guarded_directory(directory)

      files = scan(directory)
      if files.empty?
        Console.say("No #{@mode == :general ? "" : "#{@mode} "}files found in #{Console.safe(directory)}.")
        return
      end

      announce(files.size, directory)
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
        opts.on("--read-only", "Inspect only: rename, copy, move, delete and open are all disabled") { @read_only = true }
        opts.on("--dry-run", "Prompt as usual but report what each action would do, changing nothing") { @dry_run = true }
        opts.on("-g", "--gui", "Open the graphical interface in your browser") { @gui = true }
        opts.on("-p", "--port PORT", Integer,
                "GUI port (default: an unused port chosen by the OS)") { |p| @port = p }
        opts.on("--[no-]browser", "GUI: launch the browser automatically (default: yes)") { |b| @browser = b }
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

    def announce(count, directory)
      Console.say("#{count} file(s) to review in #{Console.safe(directory)} — #{@mode} mode.")
      Console.say("Read-only mode: nothing will be modified, opened, or deleted.") if @read_only
      Console.say("Dry run: every action will be reported but no file will be changed.") if dry_run?
    end

    # Read-only wins if both flags are given: there is nothing left to
    # simulate once every action that touches a file is switched off.
    def dry_run?
      @dry_run && !@read_only
    end

    # Starts the local web GUI; the terminal is only used for the banner and
    # for the same guarded-directory confirmation the prompt-driven mode asks.
    def run_gui
      abort("file_organizer: --port must be between 0 and 65535.") unless (0..65_535).cover?(@port)

      directory = File.expand_path(@directory_arg || Dir.pwd)
      error = Directory.error(directory)
      abort("file_organizer: #{Console.safe(error)}") if error
      return unless confirm_guarded_directory(directory)

      require_relative "gui"
      Gui.start(directory: directory, mode: @mode, port: @port, open_browser: @browser,
                read_only: @read_only, dry_run: dry_run?)
    rescue Interrupt
      Console.say("\nStopped.")
    end

    def resolve_directory
      if @directory_arg
        directory = File.expand_path(@directory_arg)
        error = Directory.error(directory)
        abort("file_organizer: #{Console.safe(error)}") if error
        return directory
      end

      loop do
        input = Console.ask("Directory to organize (blank to quit):")
        return nil if input.nil? || input.empty?

        directory = File.expand_path(input)
        error = Directory.error(directory)
        return directory if error.nil?

        Console.say("  #{Console.safe(error)}")
      end
    end

    def confirm_guarded_directory(directory)
      return true if @read_only || !Directory.guarded?(directory)

      Console.say("#{Console.safe(directory)} is a system or home directory — its files are")
      Console.say("almost certainly not what you meant to reorganize.")
      return true if Console.confirm_exactly_yes?("Review it anyway?")

      Console.say("Cancelled. Re-run with --read-only to look without touching anything.")
      false
    end

    # Regular files and symlinks only — subdirectories are never touched.
    # One lstat per entry: in general mode the file's content is not read at
    # all until that file is actually reached.
    def scan(directory)
      files, _truncated = Directory.entries(directory)
      files.select { |info| include_in_mode?(info) }
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

        action = normalize(choice)
        next unless permitted?(action)

        case action
        when :open then open_file(info)
        when :view then view_file(info)
        when :rename then info = rename_file(info)
        when :copy then copy_file(info)
        when :move then return if move_file(info)
        when :delete then return if Actions.delete(info.path, dry_run: dry_run?).nil?
        when :hash then show_checksum(info)
        when :next then return
        when :quit then throw :quit
        else Console.say("  Unrecognized option — type one of the letters shown above.")
        end
      end
    end

    def permitted?(action)
      return true unless @read_only && MUTATING_ACTIONS.include?(action)

      Console.say("  Read-only mode: [#{action}] is disabled.")
      false
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
      parts << "[o]pen" if !@read_only && info.openable?
      parts << "[v]iew" if info.textual?
      parts.concat(mutating_menu_parts(info)) unless @read_only
      parts << "[h]ash" if info.regular?
      parts.push("[n]ext", "[q]uit")
      "\n  #{parts.join('  ')}\n  Choice [n]:"
    end

    def mutating_menu_parts(info)
      parts = ["[r]ename"]
      parts.push("[c]opy", "[m]ove") if info.regular?
      parts << "[d]elete"
      parts
    end

    def normalize(input)
      return :next if input.empty?

      MENU_KEYS[input.downcase]
    end

    def open_file(info)
      unless info.openable?
        Console.say("  Opening is disabled for this file (executable content, a launcher file type, or not a regular file).")
        return
      end
      if info.extension_mismatch?
        Console.say("  This file's extension disagrees with its actual content — a common disguise.")
        Console.say("  The system will pick the application from the extension, not from the content.")
        return unless Console.confirm_exactly_yes?("Open it anyway?")
      end
      return if dry_run? && preview_open

      if Viewer.open_with_default_app(info.path)
        Console.say("  Opened with the system default application.")
      else
        Console.say("  Could not open the file (no system opener available).")
      end
    end

    def preview_open
      Console.say("  [dry run] would hand the file to the system default application.")
      true
    end

    def view_file(info)
      unless info.textual?
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
      new_path = Actions.rename(info.path, dry_run: dry_run?)
      new_path == info.path ? info : FileInfo.new(new_path)
    rescue SystemCallError => e
      Console.say("  Could not re-read the file after renaming: #{e.message}")
      info
    end

    def copy_file(info)
      if info.regular?
        Actions.copy(info.path, dry_run: dry_run?)
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
      Actions.move(info.path, dry_run: dry_run?).nil?
    end

    def show_checksum(info)
      unless info.regular?
        Console.say("  Checksums are only available for regular files.")
        return
      end
      Console.say("  Computing SHA-256 (may take a moment for large files)…") if info.size > 50 * 1024 * 1024
      Console.field("SHA-256", SafeFile.sha256(info.path))
    rescue SystemCallError, IOError => e
      Console.say("  Could not compute checksum: #{e.message}")
    end
  end
end
