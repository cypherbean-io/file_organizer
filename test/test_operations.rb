# frozen_string_literal: true

require_relative "helper"
require "minitest/mock"

# Operations is the shared core behind both front ends, so these tests call
# it directly: no prompts, just a Result for every outcome.

class TestOperationsRename < Minitest::Test
  include OrganizerTest

  def test_renames_a_file_and_returns_the_new_path
    file = write("before.txt", "content\n")
    result = Operations.rename(file, "after.txt")

    assert result.ok?
    assert_equal path("after.txt"), result.path
    assert_equal "content\n", File.read(path("after.txt"))
    refute_path_exists file
  end

  def test_check_is_ready_and_touches_nothing
    file = write("before.txt")
    check = Operations.check_rename(file, "after.txt")

    assert check.ready?
    assert_equal file, check.path
    assert_equal path("after.txt"), check.target
    assert_equal false, check.exists
    assert_path_exists file
    refute_path_exists path("after.txt")
  end

  def test_rejects_invalid_names_without_touching_the_disk
    file = write("before.txt")
    names = [
      "", ".", "..", "a/b", "../escaped.txt", "nul\0byte", "bell\a.txt", "del\x7F.txt",
      "line\nbreak", "esc\e[31m", "next\u0085line", "csi\u009B31m", "x" * 256, nil
    ]
    names.each do |name|
      [Operations.check_rename(file, name), Operations.rename(file, name)].each do |result|
        assert result.error?, name.inspect
        assert_equal file, result.path
        assert_includes result.message, "Invalid name"
      end
    end
    assert_equal [File.basename(file)], Dir.children(@dir)
  end

  # Regression: valid_filename? used to run /\p{Cc}/ on the name itself, which
  # raises ArgumentError ("invalid byte sequence in UTF-8") for a name that is
  # not valid UTF-8. The checks are byte-wise now, so such a name is judged
  # on its bytes instead of crashing the caller.
  def test_names_that_are_not_valid_utf8_are_judged_byte_wise
    file = write("before.txt")
    rejected = ["caf\xE9\n.txt", "\xFF\x01".b, "c1\xC2\x9B[31m".b, "\xC2\x85".b]
    rejected.each do |name|
      result = Operations.check_rename(file, name)
      assert result.error?, name.inspect
    end

    accepted = "caf\xE9.txt"
    refute accepted.valid_encoding?
    result = Operations.rename(file, accepted)
    assert result.ok?, result.message
    assert File.file?(File.join(@dir, accepted))
  end

  # C1 controls are U+0080..U+009F, i.e. \xC2 followed by \x80..\x9F in
  # UTF-8. Other characters that share the \xC2 lead byte are ordinary text.
  def test_only_c1_controls_are_rejected_among_two_byte_characters
    ["price£.txt", "no\u00A0break", "¿.txt", "Â.txt", "Ÿ.txt"].each do |name|
      assert Operations.valid_filename?(name), name.inspect
    end
    ["\u0080", "a\u009Fb", "Â\u0080"].each do |name|
      refute Operations.valid_filename?(name), name.inspect
    end
  end

  def test_refuses_to_replace_an_existing_file
    file = write("before.txt")
    write("taken.txt", "do not lose me\n")
    [Operations.check_rename(file, "taken.txt"), Operations.rename(file, "taken.txt")].each do |result|
      assert result.conflict?
      assert_equal file, result.path
      assert_includes result.message, "taken.txt"
    end

    assert_equal "do not lose me\n", File.read(path("taken.txt"))
    assert_path_exists file
  end

  def test_refuses_to_replace_a_symlink_live_or_dangling
    file = write("before.txt")
    outside = write("outside/target.txt", "outside\n")
    File.symlink(outside, path("live-link"))
    File.symlink(path("nowhere"), path("dangling-link"))

    ["live-link", "dangling-link"].each do |name|
      assert Operations.check_rename(file, name).conflict?, name
      assert Operations.rename(file, name).conflict?, name
      assert File.symlink?(path(name)), name
    end
    assert_equal "outside\n", File.read(outside)
    assert_path_exists file
  end

  # A case-insensitive volume shows one file under both "notes.txt" and
  # "Notes.txt", so File.identical? is true for the pair. A hard link gives
  # exactly that picture on a case-sensitive filesystem. Such a rename is a
  # rename of the file onto itself, not a collision with another file.
  def test_a_name_that_is_the_same_file_is_not_a_collision
    file = write("notes.txt", "keep me\n")
    File.link(file, path("Notes.txt"))
    assert File.identical?(file, path("Notes.txt"))

    check = Operations.check_rename(file, "Notes.txt")
    assert check.ready?, check.message

    result = Operations.rename(file, "Notes.txt")
    assert result.ok?, result.message
    assert_equal path("Notes.txt"), result.path
    assert_equal "keep me\n", File.read(path("Notes.txt"))
  end

  def test_case_only_rename_on_a_case_sensitive_filesystem
    file = write("notes.txt", "keep me\n")
    result = Operations.rename(file, "Notes.txt")

    assert result.ok?, result.message
    assert_equal path("Notes.txt"), result.path
    assert_equal ["Notes.txt"], Dir.children(@dir)
  end

  def test_dry_run_reports_without_renaming
    file = write("before.txt")
    result = Operations.rename(file, "after.txt", dry_run: true)

    assert result.ok?
    assert_equal file, result.path
    assert result.message.start_with?("[dry run] would"), result.message
    assert_includes result.message, "rename"
    assert_path_exists file
    refute_path_exists path("after.txt")
  end

  def test_dry_run_still_refuses_what_a_real_rename_would
    file = write("before.txt")
    write("taken.txt")

    assert Operations.rename(file, "taken.txt", dry_run: true).conflict?
    assert Operations.rename(file, "a/b", dry_run: true).error?
  end

  def test_renames_a_symlink_and_not_its_target
    target = write("target.txt", "target content\n")
    File.symlink(target, path("link"))
    result = Operations.rename(path("link"), "renamed-link")

    assert result.ok?, result.message
    assert File.symlink?(path("renamed-link"))
    refute File.symlink?(path("link"))
    assert_equal "target content\n", File.read(target)
  end

  # An existing name with a control character in it is a single path
  # component, so the file can still be renamed to something clean.
  def test_a_file_with_a_control_character_in_its_name_can_be_cleaned_up
    file = write("bell\a.txt", "content\n")
    result = Operations.rename(file, "clean.txt")

    assert result.ok?, result.message
    assert_equal "content\n", File.read(path("clean.txt"))
    refute_path_exists file
  end

  # Regression: File.identical? follows links, so a symlink and its target
  # counted as "the same file", the collision check was skipped, and the
  # rename replaced the target with a link to itself — its content gone.
  def test_renaming_a_symlink_onto_the_name_of_its_own_target_is_a_conflict
    target = write("a.txt", "precious\n")
    File.symlink(target, path("link"))
    result = Operations.rename(path("link"), "a.txt")

    assert result.conflict?, result.inspect
    refute File.symlink?(target)
    assert_equal "precious\n", File.read(target)
    assert File.symlink?(path("link"))
  end

  def test_renaming_a_file_onto_a_symlink_that_points_at_it_is_a_conflict
    file = write("a.txt", "content\n")
    File.symlink(file, path("link"))
    result = Operations.rename(file, "link")

    assert result.conflict?, result.inspect
    assert File.symlink?(path("link"))
    assert_equal "content\n", File.read(file)
  end

  # Two hard links are two names for one file; renaming one onto the other
  # used to report success while nothing happened.
  def test_renaming_a_file_onto_another_hard_link_to_it_is_a_conflict
    file = write("a.txt", "content\n")
    File.link(file, path("b.txt"))
    result = Operations.rename(file, "b.txt")

    assert result.conflict?, result.inspect
    assert_equal %w[a.txt b.txt], Dir.children(@dir).sort
  end

  def test_renaming_to_the_same_name_does_nothing
    file = write("a.txt")
    result = Operations.rename(file, "a.txt")

    assert result.ok?
    assert_equal file, result.path
    assert_includes result.message, "nothing to do"
  end

  def test_missing_source_is_an_error_not_an_exception
    result = Operations.rename(path("missing.txt"), "after.txt")

    assert result.error?
    assert_equal path("missing.txt"), result.path
    assert_includes result.message, "Rename failed"
    refute_path_exists path("after.txt")
  end
end

class TestOperationsTransfer < Minitest::Test
  include OrganizerTest

  def setup
    super
    @source = write("src/report.txt", "payload\n")
    @destination = mkdir("dest")
    @target = File.join(@destination, "report.txt")
  end

  def test_check_is_ready_for_a_free_name_and_touches_nothing
    check = Operations.check_transfer(@source, @destination)

    assert check.ready?
    assert_equal @source, check.path
    assert_equal @target, check.target
    assert_equal false, check.exists
    refute_path_exists @target
  end

  def test_missing_destination
    result = Operations.check_transfer(@source, path("no/such/dir"))

    assert result.error?
    assert_equal @source, result.path
    assert result.message.start_with?("Does not exist"), result.message
    refute_path_exists path("no")
  end

  def test_unwritable_destination
    File.chmod(0o555, @destination)
    begin
      %i[copy move].each do |operation|
        result = Operations.transfer(@source, @destination, operation)
        assert result.error?, operation.to_s
        assert result.message.start_with?("Directory is not writable"), result.message
      end
    ensure
      File.chmod(0o755, @destination)
    end
    assert_path_exists @source
    refute_path_exists @target
  end

  def test_destination_that_is_not_a_directory
    result = Operations.copy(@source, @source)

    assert result.error?
    assert result.message.start_with?("Not a directory"), result.message
    assert_equal "payload\n", File.read(@source)
  end

  # File.expand_path raises ArgumentError for "~user" when the user does not
  # exist; that must come back as an :error, not escape as an exception.
  def test_home_of_an_unknown_user_as_destination
    destination = "~file_organizer_no_such_user_#{Process.pid}"
    [Operations.check_transfer(@source, destination), Operations.move(@source, destination)].each do |result|
      assert result.error?
      assert_equal @source, result.path
      refute_empty result.message
    end
    assert_path_exists @source
  end

  def test_same_file_is_a_no_op
    source_dir = File.dirname(@source)
    results = [
      Operations.check_transfer(@source, source_dir),
      Operations.copy(@source, source_dir),
      Operations.move(@source, source_dir),
      Operations.move(@source, "#{source_dir}/", overwrite: true)
    ]
    results.each do |result|
      assert result.ok?
      assert_equal @source, result.path
      assert_includes result.message, "same file"
    end
    assert_equal "payload\n", File.read(@source)
    assert_equal ["report.txt"], Dir.children(source_dir)
  end

  # Regression: FileUtils.cp follows a symbolic link at the destination, so a
  # link planted there sent the write wherever it pointed. Not even an
  # explicit overwrite may write through one.
  def test_symlink_at_the_target_is_refused_even_with_overwrite
    outside = write("outside/precious.txt", "must survive\n")
    File.symlink(outside, @target)

    %i[copy move].each do |operation|
      [false, true].each do |overwrite|
        result = Operations.transfer(@source, @destination, operation, overwrite: overwrite)
        assert result.error?, "#{operation} overwrite=#{overwrite}"
        assert_equal @source, result.path
        assert_includes result.message, "symbolic link"
      end
    end
    assert Operations.check_transfer(@source, @destination, overwrite: true).error?

    assert_equal "must survive\n", File.read(outside)
    assert File.symlink?(@target)
    assert_equal outside, File.readlink(@target)
    assert_equal "payload\n", File.read(@source)
  end

  def test_dangling_symlink_at_the_target_is_refused
    File.symlink(path("outside/not-yet.txt"), @target)
    result = Operations.copy(@source, @destination, overwrite: true)

    assert result.error?
    assert_includes result.message, "symbolic link"
    refute_path_exists path("outside/not-yet.txt")
    assert File.symlink?(@target)
  end

  def test_directory_at_the_target_is_refused
    FileUtils.mkdir_p(@target)

    %i[copy move].each do |operation|
      result = Operations.transfer(@source, @destination, operation, overwrite: true)
      assert result.error?, operation.to_s
      assert_includes result.message, "is a directory"
    end
    assert File.directory?(@target)
    assert_empty Dir.children(@target)
    assert_path_exists @source
  end

  def test_existing_file_is_a_conflict_without_overwrite
    File.binwrite(@target, "original\n")

    check = Operations.check_transfer(@source, @destination)
    assert check.conflict?
    assert_equal @source, check.path
    assert_includes check.message, "report.txt already exists"

    %i[copy move].each do |operation|
      assert Operations.transfer(@source, @destination, operation).conflict?, operation.to_s
      assert Operations.transfer(@source, @destination, operation, dry_run: true).conflict?, operation.to_s
    end
    assert_equal "original\n", File.read(@target)
    assert_equal "payload\n", File.read(@source)
  end

  def test_check_with_overwrite_is_ready_and_says_the_target_exists
    File.binwrite(@target, "original\n")
    check = Operations.check_transfer(@source, @destination, overwrite: true)

    assert check.ready?
    assert_equal true, check.exists
    assert_equal @target, check.target
    assert_equal "original\n", File.read(@target)
  end

  def test_copy_with_overwrite_replaces_a_regular_file
    File.binwrite(@target, "original, and longer than the payload\n")
    result = Operations.copy(@source, @destination, overwrite: true)

    assert result.ok?, result.message
    assert_equal @source, result.path
    assert_equal "payload\n", File.read(@target)
    assert_equal "payload\n", File.read(@source)
  end

  def test_move_with_overwrite_replaces_a_regular_file
    File.binwrite(@target, "original\n")
    result = Operations.move(@source, @destination, overwrite: true)

    assert result.ok?, result.message
    assert_nil result.path
    assert_equal "payload\n", File.read(@target)
    refute_path_exists @source
  end

  def test_move_returns_nil_and_removes_the_source
    result = Operations.move(@source, @destination)

    assert result.ok?, result.message
    assert_nil result.path
    assert_includes result.message, @target
    refute_path_exists @source
    assert_equal "payload\n", File.read(@target)
  end

  def test_copy_keeps_the_source_and_returns_its_path
    result = Operations.copy(@source, @destination)

    assert result.ok?, result.message
    assert_equal @source, result.path
    assert_equal "payload\n", File.read(@source)
    assert_equal "payload\n", File.read(@target)
  end

  def test_only_regular_files_can_be_transferred
    link_target = write("src/real.txt", "real\n")
    link = path("src/link.txt")
    File.symlink(link_target, link)
    directory = mkdir("src/subdir")

    [link, directory].each do |source|
      %i[copy move].each do |operation|
        result = Operations.transfer(source, @destination, operation, overwrite: true)
        assert result.error?, "#{operation} #{source}"
        assert_equal source, result.path
        assert_includes result.message, "Only regular files"
      end
    end
    assert File.symlink?(link)
    assert_equal "real\n", File.read(link_target)
    assert File.directory?(directory)
    assert_empty Dir.children(@destination)
  end

  def test_missing_source_is_an_error_not_an_exception
    missing = path("src/missing.txt")
    [Operations.check_transfer(missing, @destination), Operations.move(missing, @destination)].each do |result|
      assert result.error?
      assert_equal missing, result.path
      assert_includes result.message, "Cannot use that file"
    end
    assert_empty Dir.children(@destination)
  end

  def test_copy_preserves_mode_and_mtime_but_strips_setuid
    File.chmod(0o4755, @source)
    skip "filesystem refused the set-user-ID bit" unless File.stat(@source).setuid?
    stamp = Time.now - 7200
    File.utime(stamp, stamp, @source)

    result = Operations.copy(@source, @destination)
    assert result.ok?, result.message

    stat = File.stat(@target)
    assert_equal 0o755, stat.mode & 0o7777
    refute stat.setuid?
    refute stat.setgid?
    assert_equal stamp.to_i, stat.mtime.to_i
    assert_equal 0o4755, File.stat(@source).mode & 0o7777
  end

  def test_copy_over_an_existing_file_takes_the_source_mode
    File.chmod(0o640, @source)
    File.binwrite(@target, "original\n")
    File.chmod(0o666, @target)

    assert Operations.copy(@source, @destination, overwrite: true).ok?
    assert_equal 0o640, File.stat(@target).mode & 0o7777
  end

  def test_dry_run_reports_without_transferring
    %i[copy move].each do |operation|
      result = Operations.transfer(@source, @destination, operation, dry_run: true)

      assert result.ok?, operation.to_s
      assert_equal @source, result.path
      assert result.message.start_with?("[dry run] would #{operation}"), result.message
    end
    assert_equal "payload\n", File.read(@source)
    refute_path_exists @target
  end

  def test_dry_run_overwrite_leaves_the_existing_file_alone
    File.binwrite(@target, "original\n")
    result = Operations.move(@source, @destination, overwrite: true, dry_run: true)

    assert result.ok?
    assert_equal @source, result.path
    assert result.message.start_with?("[dry run] would"), result.message
    assert_equal "original\n", File.read(@target)
    assert_path_exists @source
  end

  # A symbolic link can appear at the target between the check and the
  # write. Simulate that race by skipping the check: the copy is written to a
  # fresh temporary file and renamed over the name, which replaces the link
  # itself and never writes to what it points at.
  def test_copy_does_not_follow_a_symlink_planted_after_the_check
    outside = write("outside/precious.txt", "must survive\n")
    File.symlink(outside, @target)

    result = Operations.stub(:target_error, nil) do
      Operations.copy(@source, @destination, overwrite: true)
    end

    assert result.ok?, result.message
    assert_equal "must survive\n", File.read(outside)
    refute File.symlink?(@target)
    assert_equal "payload\n", File.read(@target)
  end

  # Without overwrite consent a name taken after the check must not be
  # replaced: the copy is put in place with link(2), which refuses.
  def test_copy_does_not_replace_a_file_created_after_the_check
    result = Operations.stub(:present?, false) do
      File.binwrite(@target, "arrived meanwhile\n")
      Operations.copy(@source, @destination)
    end

    assert result.error?, result.message
    assert_equal "arrived meanwhile\n", File.read(@target)
    assert_empty Dir.children(@destination).grep(/\.part\z/), "the temporary file is cleaned up"
  end

  # An interrupted copy must leave neither a partial file under the real
  # name nor a stray temporary file.
  def test_a_copy_that_fails_midway_leaves_nothing_behind
    File.binwrite(@target, "original\n")
    result = IO.stub(:copy_stream, ->(*) { raise Errno::ENOSPC }) do
      Operations.copy(@source, @destination, overwrite: true)
    end

    assert result.error?
    assert_includes result.message, "Copy failed"
    assert_equal "original\n", File.read(@target)
    assert_equal ["report.txt"], Dir.children(@destination)
  end

  # A named pipe at the target name used to pass the check, and the copy
  # then blocked forever opening it for writing.
  def test_a_fifo_at_the_target_is_refused_even_with_overwrite
    File.mkfifo(@target)
    check = Operations.check_transfer(@source, @destination, overwrite: true)

    assert check.error?, check.inspect
    assert_includes check.message, "not a regular file"
    assert File.pipe?(@target)
  end

  # Makes link(2) and rename(2) of the source fail as they do across
  # filesystems, while leaving the copy's own temporary file alone.
  def across_filesystems(&block)
    link = File.method(:link)
    rename = File.method(:rename)
    cross = lambda do |original|
      ->(from, to) { from == @source ? raise(Errno::EXDEV) : original.call(from, to) }
    end
    File.stub(:link, cross.call(link)) { File.stub(:rename, cross.call(rename), &block) }
  end

  # link(2) and rename(2) cannot cross filesystems; the move then falls back
  # to the copy and removes the source only afterwards.
  def test_move_across_filesystems_falls_back_to_copy_and_unlink
    File.chmod(0o640, @source)
    stamp = Time.now - 3600
    File.utime(stamp, stamp, @source)
    source_inode = File.stat(@source).ino

    result = across_filesystems { Operations.move(@source, @destination) }

    assert result.ok?, result.message
    assert_nil result.path
    refute_path_exists @source
    assert_equal "payload\n", File.read(@target)
    assert_equal 0o640, File.stat(@target).mode & 0o7777
    assert_equal stamp.to_i, File.mtime(@target).to_i
    refute_equal source_inode, File.stat(@target).ino, "the fallback copy really ran"
  end

  def test_failed_cross_filesystem_copy_keeps_the_source
    result = across_filesystems do
      Operations.stub(:copy_bytes, ->(*, **) { raise Errno::ENOSPC }) do
        Operations.move(@source, @destination)
      end
    end

    assert result.error?
    assert_equal @source, result.path
    assert_includes result.message, "Move failed"
    assert_equal "payload\n", File.read(@source)
  end
end

class TestOperationsDelete < Minitest::Test
  include OrganizerTest

  def test_deletes_a_file
    file = write("gone.txt")
    result = Operations.delete(file)

    assert result.ok?
    assert_nil result.path
    assert_includes result.message, "gone.txt"
    refute_path_exists file
  end

  def test_deleting_a_symlink_removes_only_the_link
    target = write("target.txt", "still here\n")
    File.symlink(target, path("link"))
    result = Operations.delete(path("link"))

    assert result.ok?
    assert_nil result.path
    refute File.symlink?(path("link"))
    assert_equal "still here\n", File.read(target)
  end

  def test_dry_run_reports_without_deleting
    file = write("keep.txt")
    result = Operations.delete(file, dry_run: true)

    assert result.ok?
    assert_equal file, result.path
    assert result.message.start_with?("[dry run] would delete"), result.message
    assert_path_exists file
  end

  def test_missing_file_is_an_error_not_an_exception
    result = Operations.delete(path("missing.txt"))

    assert result.error?
    assert_equal path("missing.txt"), result.path
    assert_includes result.message, "Delete failed"
  end

  def test_does_not_delete_a_directory
    directory = mkdir("subdir")
    write("subdir/inside.txt")
    result = Operations.delete(directory)

    assert result.error?
    assert_path_exists File.join(directory, "inside.txt")
  end
end

class TestOperationsNames < Minitest::Test
  include OrganizerTest

  def test_ordinary_names_are_valid_and_single_components
    ["notes.txt", ".hidden", "with space.txt", "café.txt", "-leading-dash", "x" * 255, "..."].each do |name|
      assert Operations.valid_filename?(name), name.inspect
      assert Operations.single_component?(name), name.inspect
    end
  end

  # An existing name may hold control characters (the filesystem allows
  # them); refusing to touch it would mean refusing to help clean it up. A
  # new name may not.
  def test_existing_names_with_control_characters_are_single_components_but_not_valid_new_names
    ["bell\a.txt", "line\nbreak", "esc\e[31m", "del\x7F", "tab\t", "next\u0085line", "\xFF\x01".b].each do |name|
      assert Operations.single_component?(name), name.inspect
      refute Operations.valid_filename?(name), name.inspect
    end
  end

  def test_traversal_and_separators_are_neither
    ["", ".", "..", "a/b", "/", "../x", "nul\0byte", "x" * 256, "é" * 128].each do |name|
      refute Operations.single_component?(name), name.inspect
      refute Operations.valid_filename?(name), name.inspect
    end
  end

  def test_a_backslash_is_never_valid_in_a_new_name
    refute Operations.valid_filename?("a\\b")
    if File::ALT_SEPARATOR
      refute Operations.single_component?("a\\b")
    else
      assert Operations.single_component?("a\\b")
    end
  end

  def test_non_strings_are_neither
    [nil, :name, 42, ["a"]].each do |name|
      refute Operations.single_component?(name), name.inspect
      refute Operations.valid_filename?(name), name.inspect
    end
  end

  def test_names_that_are_not_valid_utf8_do_not_raise
    name = "caf\xE9.txt"
    refute name.valid_encoding?
    assert Operations.single_component?(name)
    assert Operations.valid_filename?(name)
    assert Operations.valid_filename?(name.b)
    refute Operations.valid_filename?("#{name}\n")
  end
end

class TestOperationsResult < Minitest::Test
  PREDICATES = { ok: :ok?, ready: :ready?, conflict: :conflict?, error: :error? }.freeze

  def test_each_predicate_matches_only_its_own_status
    PREDICATES.each_key do |status|
      result = FileOrganizer::Operations::Result.new(status: status, path: "/x")
      PREDICATES.each do |other, predicate|
        assert_equal status == other, result.public_send(predicate), "#{status} #{predicate}"
      end
    end
  end

  def test_an_unknown_status_matches_no_predicate
    result = FileOrganizer::Operations::Result.new(status: :something_else)
    PREDICATES.each_value { |predicate| refute result.public_send(predicate), predicate }
  end

  def test_fields_are_keyword_initialised
    result = FileOrganizer::Operations::Result.new(status: :ready, path: "/a", target: "/b/a", exists: true)

    assert_equal "/a", result.path
    assert_equal "/b/a", result.target
    assert_equal true, result.exists
    assert_nil result.message
  end
end
