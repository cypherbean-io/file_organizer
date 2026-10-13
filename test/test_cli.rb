# frozen_string_literal: true

require_relative "helper"

class TestCLIMenuParsing < Minitest::Test
  include OrganizerTest

  def setup
    super
    @cli = CLI.new([@dir])
  end

  def normalize(input)
    @cli.send(:normalize, input)
  end

  def test_single_letters_and_full_words_select_actions
    assert_equal :delete, normalize("d")
    assert_equal :delete, normalize("delete")
    assert_equal :delete, normalize("DELETE")
    assert_equal :move, normalize("m")
    assert_equal :quit, normalize("q")
  end

  def test_enter_advances_to_the_next_file
    assert_equal :next, normalize("")
  end

  # Regression: matching on the first letter alone meant that typing "done"
  # started a delete and "move it later" moved the file outright.
  def test_words_that_merely_start_with_an_action_letter_are_not_actions
    ["done", "dir", "move it later", "rename?", "copy that", "nope please", "ok"].each do |input|
      assert_nil normalize(input), input
    end
  end
end

class TestCLIOpenGuards < Minitest::Test
  include OrganizerTest

  def openable?(name, content)
    CLI.new([@dir]).send(:openable?, FileInfo.new(write(name, content)))
  end

  def test_plain_documents_can_be_opened
    assert openable?("notes.txt", "hello\n")
  end

  def test_executable_content_cannot_be_opened
    refute openable?("tool", "\x7FELF\x02\x01\x01\x00padding".b)
  end

  def test_files_with_the_executable_bit_cannot_be_opened
    file = write("run.txt", "hello\n")
    File.chmod(0o755, file)
    refute CLI.new([@dir]).send(:openable?, FileInfo.new(file))
  end

  # A .desktop entry is inert text that tells the desktop to run an arbitrary
  # command line; xdg-open on one executes it.
  def test_launcher_file_types_cannot_be_opened_whatever_the_content_looks_like
    refute openable?("innocent.desktop", "[Desktop Entry]\nExec=rm -rf ~\n")
    refute openable?("shortcut.lnk", "plain text\n")
    refute openable?("installer.msi", "plain text\n")
  end
end

class TestCLIReadOnlyMode < Minitest::Test
  include OrganizerTest

  def test_menu_offers_no_action_that_changes_anything
    info = FileInfo.new(write("notes.txt"))
    prompt = CLI.new(["--read-only", @dir]).send(:menu_prompt, info)

    ["[o]pen", "[r]ename", "[c]opy", "[m]ove", "[d]elete"].each do |entry|
      refute_includes prompt, entry
    end
    assert_includes prompt, "[v]iew"
    assert_includes prompt, "[h]ash"
  end

  def test_mutating_actions_are_refused
    cli = CLI.new(["--read-only", @dir])
    %i[open rename copy move delete].each do |action|
      refute answering { cli.send(:permitted?, action) }
    end
    assert answering { cli.send(:permitted?, :view) }
    assert answering { cli.send(:permitted?, :hash) }
  end

  def test_a_whole_session_leaves_every_file_untouched
    file = write("notes.txt", "original\n")
    answering("d", "yes", "r", "other.txt", "y", "q") { CLI.new(["--read-only", @dir]).run }

    assert_equal "original\n", File.read(file)
    assert_includes output, "Read-only mode"
  end
end

class TestCLISession < Minitest::Test
  include OrganizerTest

  # Regression: any word starting with "d" used to open the delete prompt.
  def test_an_unrecognized_word_does_nothing
    file = write("keep.txt")
    answering("done", "q") { CLI.new([@dir]).run }

    assert_includes output, "Unrecognized option"
    assert_path_exists file
  end

  def test_dry_run_reports_a_delete_without_performing_it
    file = write("keep.txt")
    answering("d", "yes", "q") { CLI.new(["--dry-run", @dir]).run }

    assert_includes output, "[dry run] would delete"
    assert_path_exists file
  end

  def test_read_only_wins_when_both_flags_are_given
    cli = CLI.new(["--dry-run", "--read-only", @dir])
    refute cli.send(:dry_run?)
    refute answering { cli.send(:permitted?, :delete) }
  end

  def test_end_of_input_quits_rather_than_choosing_an_action
    file = write("keep.txt")
    answering { CLI.new([@dir]).run }

    assert_path_exists file
  end

  def test_system_and_home_directories_need_an_explicit_confirmation
    cli = CLI.new([@dir])
    %w[/ /etc /etc/nginx /usr/local/bin /var].each do |directory|
      assert cli.send(:guarded_directory?, directory), directory
    end
    assert cli.send(:guarded_directory?, File.expand_path(Dir.home))
    refute cli.send(:guarded_directory?, @dir)
  end

  def test_scan_lists_files_and_symlinks_but_never_subdirectories
    write("a.txt")
    File.symlink(write("b.txt"), path("link"))
    mkdir("subdir")
    write("subdir/c.txt")

    names = CLI.new([@dir]).send(:scan, @dir).map(&:name)
    assert_equal %w[a.txt b.txt link], names.sort
  end

  # Reading the head of every file up front made listing a large directory
  # pay for content it may never show.
  def test_general_mode_does_not_read_file_contents_while_listing
    3.times { |i| write("f#{i}.bin", "\x00" * 4096) }

    files = nil
    assert_equal 0, count_file_opens { files = CLI.new([@dir]).send(:scan, @dir) }
    assert_equal 3, files.size

    assert_equal 1, count_file_opens { files.first.detection }
    assert_equal 0, count_file_opens { files.first.detection }
  end
end

class TestCLIChecksum < Minitest::Test
  include OrganizerTest

  def checksum(file)
    CLI.new([@dir]).send(:checksum, file)
  end

  def test_matches_the_digest_of_the_whole_file
    content = "a" * ((1 << 20) + 12_345) # spans more than one read chunk
    file = write("big.bin", content)

    assert_equal Digest::SHA256.hexdigest(content), checksum(file)
  end

  def test_handles_an_empty_file
    assert_equal Digest::SHA256.hexdigest(""), checksum(write("empty.bin", ""))
  end

  def test_does_not_follow_a_symlink
    File.symlink(write("real.bin", "content"), path("link"))

    assert_raises(SystemCallError) { checksum(path("link")) }
  end
end
