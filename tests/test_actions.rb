# frozen_string_literal: true

require_relative "helper"

class TestActionsRename < Minitest::Test
  include OrganizerTest

  def test_renames_after_confirmation
    file = write("before.txt")
    result = answering("after.txt", "y") { Actions.rename(file) }

    assert_equal path("after.txt"), result
    assert_path_exists path("after.txt")
    refute_path_exists file
  end

  def test_declining_the_confirmation_leaves_the_file_alone
    file = write("before.txt")
    result = answering("after.txt", "") { Actions.rename(file) }

    assert_equal file, result
    assert_path_exists file
    refute_path_exists path("after.txt")
  end

  def test_blank_name_cancels
    file = write("before.txt")
    assert_equal file, answering("") { Actions.rename(file) }
    assert_path_exists file
  end

  def test_rejects_names_that_are_not_a_single_path_component
    file = write("before.txt")
    ["../escaped.txt", "sub/nested.txt", "back\\slash.txt", "..", ".", "bell\a.txt"].each do |name|
      assert_equal file, answering(name, "y") { Actions.rename(file) }
      assert_includes output, "Invalid name"
    end
    assert_path_exists file
    refute_path_exists File.join(File.dirname(@dir), "escaped.txt")
  end

  def test_refuses_to_replace_an_existing_file
    file = write("before.txt")
    write("taken.txt", "do not lose me\n")
    assert_equal file, answering("taken.txt", "y") { Actions.rename(file) }

    assert_equal "do not lose me\n", File.read(path("taken.txt"))
    assert_path_exists file
  end

  def test_refuses_to_replace_an_existing_symlink
    file = write("before.txt")
    File.symlink(write("target.txt"), path("link.txt"))
    assert_equal file, answering("link.txt", "y") { Actions.rename(file) }

    assert File.symlink?(path("link.txt"))
    assert_path_exists file
  end

  def test_dry_run_reports_without_renaming
    file = write("before.txt")
    assert_equal file, answering("after.txt", "y") { Actions.rename(file, dry_run: true) }

    assert_includes output, "[dry run] would rename"
    assert_path_exists file
    refute_path_exists path("after.txt")
  end

  def test_renames_a_symlink_and_not_its_target
    target = write("target.txt", "target content\n")
    File.symlink(target, path("link"))
    answering("renamed-link", "y") { Actions.rename(path("link")) }

    assert File.symlink?(path("renamed-link"))
    assert_path_exists target
    assert_equal "target content\n", File.read(target)
  end
end

class TestActionsDelete < Minitest::Test
  include OrganizerTest

  def test_requires_the_whole_word_yes
    file = write("keep.txt")
    ["y", "", "sure", "YES"].each do |answer|
      assert_equal file, answering(answer) { Actions.delete(file) }
      assert_path_exists file
    end
  end

  def test_deletes_when_confirmed
    file = write("gone.txt")
    assert_nil answering("yes") { Actions.delete(file) }
    refute_path_exists file
  end

  def test_deletes_a_symlink_without_touching_its_target
    target = write("target.txt", "still here\n")
    File.symlink(target, path("link"))
    assert_nil answering("yes") { Actions.delete(path("link")) }

    refute File.symlink?(path("link"))
    assert_equal "still here\n", File.read(target)
  end

  def test_dry_run_reports_without_deleting
    file = write("keep.txt")
    assert_equal file, answering("yes") { Actions.delete(file, dry_run: true) }

    assert_includes output, "[dry run] would delete"
    assert_path_exists file
  end
end

class TestActionsTransfer < Minitest::Test
  include OrganizerTest

  def setup
    super
    @source = write("src/report.txt", "payload\n")
    @destination = mkdir("dest")
  end

  # Regression: FileUtils.cp follows a symbolic link at the destination, so a
  # link planted there sent the write to whatever it pointed at — a file
  # outside the directory the user chose, and never named in the prompt.
  def test_copy_refuses_to_write_through_a_symlink_at_the_destination
    outside = write("outside/precious.txt", "must survive\n")
    File.symlink(outside, File.join(@destination, "report.txt"))

    assert_equal @source, answering(@destination, "yes") { Actions.copy(@source) }
    assert_includes output, "symbolic link"
    assert_equal "must survive\n", File.read(outside)
  end

  def test_move_refuses_to_write_through_a_symlink_at_the_destination
    outside = write("outside/precious.txt", "must survive\n")
    File.symlink(outside, File.join(@destination, "report.txt"))

    assert_equal @source, answering(@destination, "yes") { Actions.move(@source) }
    assert_equal "must survive\n", File.read(outside)
    assert_path_exists @source
  end

  def test_refuses_a_directory_at_the_destination_name
    FileUtils.mkdir_p(File.join(@destination, "report.txt"))

    assert_equal @source, answering(@destination, "yes") { Actions.copy(@source) }
    assert_includes output, "is a directory"
    assert File.directory?(File.join(@destination, "report.txt"))
  end

  def test_copy_needs_confirmation
    assert_equal @source, answering(@destination, "") { Actions.copy(@source) }
    refute_path_exists File.join(@destination, "report.txt")
  end

  def test_copies_content_permissions_and_timestamp
    File.chmod(0o640, @source)
    stamp = Time.now - 7200
    File.utime(stamp, stamp, @source)

    assert_equal @source, answering(@destination, "y") { Actions.copy(@source) }
    copy = File.join(@destination, "report.txt")

    assert_equal "payload\n", File.read(copy)
    assert_equal 0o640, File.stat(copy).mode & 0o777
    assert_equal stamp.to_i, File.mtime(copy).to_i
    assert_path_exists @source
  end

  def test_overwriting_an_existing_file_takes_the_strict_confirmation
    existing = File.join(@destination, "report.txt")
    File.binwrite(existing, "original\n")

    assert_equal @source, answering(@destination, "y") { Actions.copy(@source) }
    assert_equal "original\n", File.read(existing)

    assert_equal @source, answering(@destination, "yes") { Actions.copy(@source) }
    assert_equal "payload\n", File.read(existing)
  end

  def test_move_removes_the_source
    assert_nil answering(@destination, "y") { Actions.move(@source) }

    refute_path_exists @source
    assert_equal "payload\n", File.read(File.join(@destination, "report.txt"))
  end

  def test_moving_into_the_same_directory_is_a_no_op
    assert_equal @source, answering(File.dirname(@source), "y") { Actions.move(@source) }

    assert_includes output, "same file"
    assert_path_exists @source
  end

  def test_dry_run_reports_without_transferring
    assert_equal @source, answering(@destination, "y") { Actions.move(@source, dry_run: true) }

    assert_includes output, "[dry run] would move"
    assert_path_exists @source
    refute_path_exists File.join(@destination, "report.txt")
  end

  def test_reports_an_unusable_destination
    assert_equal @source, answering(path("no/such/dir")) { Actions.copy(@source) }
    assert_includes output, "Does not exist"

    assert_equal @source, answering(@source) { Actions.copy(@source) }
    assert_includes output, "Not a directory"
  end
end

class TestActionsFilenameValidation < Minitest::Test
  include OrganizerTest

  def test_accepts_ordinary_names
    ["notes.txt", ".hidden", "with space.txt", "café.txt", "-leading-dash"].each do |name|
      assert Actions.valid_filename?(name), name
    end
  end

  def test_rejects_traversal_separators_and_control_characters
    ["..", ".", "a/b", "a\\b", "nul\0byte", "esc\e[0m", "\n", "x" * 256].each do |name|
      refute Actions.valid_filename?(name), name.inspect
    end
  end
end
