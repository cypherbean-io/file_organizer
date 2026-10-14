# frozen_string_literal: true

require_relative "helper"
require_relative "../lib/file_organizer/gui"

# Shared fixtures for the directory listing, the GUI session built on it, and
# the FileInfo predicates the GUI relies on.
module DirectorySessionTest
  include OrganizerTest

  PNG_MAGIC = "\x89PNG\r\n\x1A\n".b.freeze
  PNG = (PNG_MAGIC + "\x00\x00\x00\x0DIHDR".b + ("\x00".b * 48)).freeze
  INVALID_UTF8_NAME = "bad\xFF.txt".b.freeze

  # A file whose name is not valid UTF-8, which the filesystem allows. Returns
  # the name as Dir.children reports it (UTF-8 encoded, invalid bytes intact).
  def write_invalid_utf8_name(content = "hello\n")
    File.binwrite(File.join(@dir, INVALID_UTF8_NAME), content)
    Dir.children(@dir).find { |name| name.b == INVALID_UTF8_NAME }
  end

  def names(entries)
    entries.map { |info| info.name.b }
  end

  def session(**options)
    @session ||= Gui::Session.new(@dir, **options)
  end

  # Runs the block with +owner::name+ set to +value+, restoring it afterwards.
  def with_constant(owner, name, value)
    original = owner.const_get(name, false)
    owner.send(:remove_const, name)
    owner.const_set(name, value)
    yield
  ensure
    owner.send(:remove_const, name) if owner.const_defined?(name, false)
    owner.const_set(name, original)
  end

  def without_permissions(dir, mode)
    skip "permission checks do not apply to root" if Process.uid.zero?
    File.chmod(mode, dir)
    yield
  ensure
    File.chmod(0o755, dir) if File.directory?(dir)
  end
end

class TestDirectoryEntries < Minitest::Test
  include DirectorySessionTest

  def test_lists_files_and_symlinks_but_not_subdirectories
    write("a.txt")
    mkdir("sub")
    File.symlink(path("a.txt"), path("link"))
    File.symlink(path("nowhere"), path("dangling"))
    File.symlink(path("sub"), path("dir-link"))
    entries, truncated = Directory.entries(@dir)

    assert_equal %w[a.txt dangling dir-link link], entries.map(&:name)
    assert entries.find { |info| info.name == "dangling" }.symlink?
    assert entries.find { |info| info.name == "a.txt" }.regular?
    refute truncated
  end

  def test_skips_named_pipes
    write("a.txt")
    File.mkfifo(path("pipe"))
    entries, = Directory.entries(@dir)

    assert_equal %w[a.txt], entries.map(&:name)
  end

  def test_sorts_case_insensitively_with_case_breaking_ties
    %w[b.txt C.txt a.txt A.txt].each { |name| write(name) }
    entries, = Directory.entries(@dir)

    assert_equal %w[A.txt a.txt b.txt C.txt], entries.map(&:name)
  end

  # Regression: sorting called String#downcase on the raw name, which raises
  # ArgumentError for a name that is not valid UTF-8.
  def test_sorts_byte_wise_without_raising_on_invalid_utf8_names
    write_invalid_utf8_name
    write("Bad.txt")
    write("apple.txt")
    entries, = Directory.entries(@dir)

    assert_equal ["apple.txt".b, "Bad.txt".b, INVALID_UTF8_NAME], names(entries)
  end

  def test_limit_truncates_and_reports_it
    %w[a b c d e].each { |name| write("#{name}.txt") }
    entries, truncated = Directory.entries(@dir, limit: 3)

    assert_equal %w[a.txt b.txt c.txt], entries.map(&:name)
    assert truncated
  end

  def test_limit_equal_to_the_entry_count_is_not_truncation
    %w[a b c].each { |name| write("#{name}.txt") }
    entries, truncated = Directory.entries(@dir, limit: 3)

    assert_equal 3, entries.size
    refute truncated
  end

  def test_without_a_limit_there_is_no_cap
    count = Gui::Session::MAX_ENTRIES + 1
    FileUtils.touch(Array.new(count) { |i| path(format("f%05d", i)) })
    entries, truncated = Directory.entries(@dir)

    assert_equal count, entries.size
    refute truncated
  end

  # Listing costs one lstat per entry; no content is read until asked for.
  def test_listing_opens_no_file
    write("a.txt")
    write("image.png", PNG)
    write("script.sh", "#!/bin/sh\necho hi\n")
    File.symlink(path("a.txt"), path("link"))
    File.mkfifo(path("pipe"))

    assert_equal 0, count_file_opens { Directory.entries(@dir) }
  end

  def test_unreadable_directory_lists_nothing
    assert_equal [[], false], Directory.entries(path("missing"))
  end
end

class TestDirectorySubdirectories < Minitest::Test
  include DirectorySessionTest

  def test_lists_real_subdirectories_only
    mkdir("b-dir")
    mkdir("A-dir")
    write("file.txt")
    File.symlink(path("A-dir"), path("linked-dir"))
    File.symlink(path("nowhere"), path("dangling"))

    assert_equal %w[A-dir b-dir], Directory.subdirectories(@dir)
  end
end

class TestDirectoryError < Minitest::Test
  include DirectorySessionTest

  def test_usable_directory_has_no_error
    assert_nil Directory.error(@dir)
    assert_nil Directory.error(@dir, access: :write)
  end

  def test_missing_directory
    missing = path("missing")
    assert_equal "does not exist: #{missing}", Directory.error(missing)
    assert_equal "does not exist: #{missing}", Directory.error(missing, access: :write)
  end

  def test_file_is_not_a_directory
    file = write("a.txt")
    assert_equal "not a directory: #{file}", Directory.error(file)
    assert_equal "not a directory: #{file}", Directory.error(file, access: :write)
  end

  def test_unreadable_directory
    dir = mkdir("locked")
    without_permissions(dir, 0o000) do
      assert_equal "directory is not readable: #{dir}", Directory.error(dir)
    end
  end

  def test_read_only_directory_is_readable_but_not_writable
    dir = mkdir("read-only")
    without_permissions(dir, 0o555) do
      assert_nil Directory.error(dir)
      assert_equal "directory is not writable: #{dir}", Directory.error(dir, access: :write)
    end
  end
end

class TestDirectoryGuarded < Minitest::Test
  include DirectorySessionTest

  def test_root_and_home_are_guarded
    assert Directory.guarded?("/")
    assert Directory.guarded?(File.expand_path(Dir.home))
  end

  def test_system_directories_and_their_contents_are_guarded
    assert Directory.guarded?("/etc")
    assert Directory.guarded?("/etc/x")
    assert Directory.guarded?("/usr/local/bin")
  end

  def test_a_shared_prefix_is_not_enough
    refute Directory.guarded?("/etcetera")
    refute Directory.guarded?("/usr2/files")
  end

  def test_an_ordinary_directory_is_not_guarded
    refute Directory.guarded?(@dir)
  end
end

class TestGuiSessionFind < Minitest::Test
  include DirectorySessionTest

  def test_resolves_an_id_to_the_file_in_the_current_directory
    file = write("notes.txt")
    info = session.find(Gui.encode_id("notes.txt"))

    assert_instance_of FileInfo, info
    assert_equal file, info.path
  end

  def test_resolves_a_name_that_is_not_valid_utf8
    name = write_invalid_utf8_name
    info = session.find(Gui.encode_id(name))

    refute_nil info
    assert_equal INVALID_UTF8_NAME, info.name.b
  end

  # The decoded name is joined onto the current directory, so nothing that is
  # not a single path component may get through.
  def test_rejects_ids_that_would_leave_the_directory
    outside = write("secret.txt")
    inner = mkdir("inner")
    write("inner/visible.txt")
    session = Gui::Session.new(inner)

    ["../secret.txt", "..", ".", outside, "sub/../../secret.txt", "visible.txt/..",
     "visible.txt\0"].each do |name|
      assert_nil session.find(Gui.encode_id(name)), "name #{name.inspect} was accepted"
    end
    refute_nil session.find(Gui.encode_id("visible.txt"))
  end

  def test_rejects_ids_that_are_not_ids
    write("notes.txt")
    [nil, 42, "", "notes.txt", "../notes.txt", "a" * 701].each do |id|
      assert_nil session.find(id), "id #{id.inspect} was accepted"
    end
  end

  def test_rejects_subdirectories
    mkdir("sub")
    assert_nil session.find(Gui.encode_id("sub"))
  end

  def test_rejects_missing_files_and_pipes
    File.mkfifo(path("pipe"))
    assert_nil session.find(Gui.encode_id("missing.txt"))
    assert_nil session.find(Gui.encode_id("pipe"))
  end

  def test_accepts_symlinks_including_dangling_ones
    File.symlink(write("target.txt"), path("link"))
    File.symlink(path("nowhere"), path("dangling"))

    assert session.find(Gui.encode_id("link")).symlink?
    assert session.find(Gui.encode_id("dangling")).symlink?
  end

  def test_find_follows_the_current_directory
    other = mkdir("other")
    write("other/inside.txt")
    assert_nil session.find(Gui.encode_id("inside.txt"))

    assert_nil session.change_directory(other)
    assert_equal File.join(other, "inside.txt"), session.find(Gui.encode_id("inside.txt")).path
  end
end

class TestGuiSessionListing < Minitest::Test
  include DirectorySessionTest

  def test_lists_the_current_directory
    write("a.txt")
    mkdir("sub")
    listing = session.listing

    assert_equal @dir, listing[:directory]
    assert_equal %w[a.txt], listing[:entries].map(&:name)
    refute listing[:truncated]
  end

  def test_caps_the_listing_at_max_entries
    %w[a b c].each { |name| write("#{name}.txt") }
    listing = with_constant(Gui::Session, :MAX_ENTRIES, 2) { session.listing }

    assert_equal %w[a.txt b.txt], listing[:entries].map(&:name)
    assert listing[:truncated]
    assert_equal 5_000, Gui::Session::MAX_ENTRIES
  end

  def test_lists_names_that_are_not_valid_utf8
    write_invalid_utf8_name
    write("apple.txt")

    assert_equal ["apple.txt".b, INVALID_UTF8_NAME], names(session.listing[:entries])
  end

  def test_subdirectories_and_parent
    mkdir("sub")
    write("file.txt")

    assert_equal %w[sub], session.subdirectories
    assert_equal File.dirname(@dir), session.parent
    assert_nil Gui::Session.new("/").parent
  end
end

class TestGuiSessionDetectionCache < Minitest::Test
  include DirectorySessionTest

  def detect_all
    session.listing[:entries].each(&:category)
  end

  def test_second_listing_of_an_unchanged_folder_reads_no_file
    write("a.txt")
    write("image.png", PNG)
    write("empty")
    File.symlink(path("a.txt"), path("link"))

    assert_equal 3, count_file_opens { detect_all }
    assert_equal 0, count_file_opens { detect_all }
  end

  def test_find_reuses_the_detection_from_the_listing
    write("image.png", PNG)
    session.listing

    category = nil
    assert_equal 0, count_file_opens { category = session.find(Gui.encode_id("image.png")).category }
    assert_equal :photo, category
  end

  def test_rewritten_file_with_a_different_size_is_detected_again
    file = write("photo.png", "just some text\n")
    write("other.txt")
    info = session.listing[:entries].find { |entry| entry.name == "photo.png" }
    assert_equal :text, info.category
    assert info.extension_mismatch?

    File.binwrite(file, PNG)
    opens = count_file_opens do
      info = session.listing[:entries].find { |entry| entry.name == "photo.png" }
      info.category
    end

    assert_equal 1, opens
    assert_equal :photo, info.category
    refute info.extension_mismatch?
  end

  def test_rewritten_file_with_the_same_size_is_detected_again
    text = "plain text here\n"
    png = PNG_MAGIC + ("\x00".b * (text.bytesize - PNG_MAGIC.bytesize))
    file = write("image", text)
    assert_equal :text, session.listing[:entries].first.category

    before = File.lstat(file)
    File.binwrite(file, png)
    File.utime(before.atime, before.mtime + 60, file)
    after = File.lstat(file)
    assert_equal [before.ino, before.size], [after.ino, after.size]

    assert_equal :photo, session.listing[:entries].first.category
  end

  def test_file_replaced_by_rename_is_detected_again
    text = "plain text here\n"
    png = PNG_MAGIC + ("\x00".b * (text.bytesize - PNG_MAGIC.bytesize))
    file = write("image", text)
    assert_equal :text, session.listing[:entries].first.category

    File.rename(write("incoming", png), file)

    assert_equal :photo, session.listing[:entries].first.category
  end

  def test_changing_directory_forgets_detections
    write("a.txt")
    other = mkdir("other")
    detect_all

    assert_nil session.change_directory(other)
    assert_nil session.change_directory(@dir)
    assert_equal 1, count_file_opens { detect_all }
  end

  def test_detection_memory_is_bounded
    %w[a b c d e].each { |name| write("#{name}.txt") }
    with_constant(Gui::Session, :MAX_DETECTIONS, 2) { detect_all }

    assert_operator session.instance_variable_get(:@detections).size, :<=, 2
  end
end

class TestGuiSessionChangeDirectory < Minitest::Test
  include DirectorySessionTest

  def test_changes_to_an_expanded_path
    other = mkdir("other")
    assert_nil session.change_directory(File.join(@dir, "other", "..", "other"))
    assert_equal other, session.directory
  end

  def test_missing_directory_is_an_error_and_keeps_the_current_one
    missing = path("missing")
    assert_equal "does not exist: #{missing}", session.change_directory(missing)
    assert_equal @dir, session.directory
  end

  def test_file_is_an_error_and_keeps_the_current_one
    file = write("a.txt")
    assert_equal "not a directory: #{file}", session.change_directory(file)
    assert_equal @dir, session.directory
  end

  def test_unreadable_directory_is_an_error
    dir = mkdir("locked")
    without_permissions(dir, 0o000) do
      assert_equal "directory is not readable: #{dir}", session.change_directory(dir)
    end
    assert_equal @dir, session.directory
  end

  # Regression: File.expand_path raises ArgumentError for an unknown user.
  def test_unknown_user_home_is_an_error_rather_than_an_exception
    error = session.change_directory("~no_such_user_file_organizer_test")

    assert_kind_of String, error
    assert_includes error, "no_such_user_file_organizer_test"
    assert_equal @dir, session.directory
  end

  def test_a_failed_change_keeps_what_is_known_about_the_files
    write("a.txt")
    session.listing[:entries].each(&:category)
    session.change_directory(path("missing"))

    assert_equal 0, count_file_opens { session.listing[:entries].each(&:category) }
  end
end

class TestGuiSessionModes < Minitest::Test
  include DirectorySessionTest

  def test_defaults_allow_changes
    refute session.read_only?
    refute session.dry_run?
    assert_equal :general, session.mode
  end

  def test_dry_run
    session = Gui::Session.new(@dir, dry_run: true)
    assert session.dry_run?
    refute session.read_only?
  end

  def test_read_only_wins_over_dry_run
    session = Gui::Session.new(@dir, read_only: true, dry_run: true)
    assert session.read_only?
    refute session.dry_run?
  end
end

class TestFileInfoSafety < Minitest::Test
  include DirectorySessionTest

  def test_plain_text_file_is_openable
    assert FileInfo.new(write("notes.txt")).openable?
  end

  def test_symlink_is_never_openable
    File.symlink(write("notes.txt"), path("link.txt"))
    refute FileInfo.new(path("link.txt")).openable?
  end

  def test_launchable_extension_is_not_openable_whatever_its_case
    %w[launcher.desktop launcher.DESKTOP shortcut.LnK run.Bat].each do |name|
      info = FileInfo.new(write(name, "[Desktop Entry]\nExec=sh\n"))
      assert info.launchable_extension?, name
      refute info.openable?, name
    end
  end

  def test_executables_are_not_openable
    script = write("tool.txt", "plain text\n")
    File.chmod(0o755, script)
    refute FileInfo.new(script).openable?
    refute FileInfo.new(write("binary.dat", "\x7FELF\x02\x01\x01".b + ("\x00".b * 32))).openable?
  end

  # Regression: an extension made of bytes that are not valid UTF-8 must not
  # make the mismatch check raise.
  def test_extension_mismatch_tolerates_invalid_utf8_in_the_extension
    file = File.join(@dir, "photo.pn\xFFg".b)
    File.binwrite(file, "just some text\n")
    name = Dir.children(@dir).first
    info = FileInfo.new(File.join(@dir, name))

    refute info.extension_mismatch?
    refute TypeDetector.extension_mismatch?(File.join(@dir, name), info.detection)
    refute TypeDetector.extension_mismatch?(file, info.detection)
  end

  def test_extension_mismatch_still_works_for_an_invalid_utf8_base_name
    File.binwrite(File.join(@dir, "bad\xFF.png".b), "just some text\n")
    info = FileInfo.new(File.join(@dir, Dir.children(@dir).first))

    assert info.extension_mismatch?
    assert TypeDetector.extension_mismatch?(info.path, info.detection)
  end
end
