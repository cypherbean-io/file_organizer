# frozen_string_literal: true

require_relative "helper"

class TestTypeDetector < Minitest::Test
  include OrganizerTest

  def detect(name, content)
    TypeDetector.detect(write(name, content))
  end

  def test_identifies_formats_by_content_not_extension
    assert_equal :png, detect("anything.mp3", "\x89PNG\r\n\x1A\n".b).format
    assert_equal :jpeg, detect("anything.txt", "\xFF\xD8\xFF\xE0".b).format
    assert_equal :gif, detect("a.bin", "GIF89a\x04\x00\x03\x00".b).format
    assert_equal :pdf, detect("a.bin", "%PDF-1.7\n").format
    assert_equal :elf, detect("a.bin", "\x7FELF\x02\x01\x01\x00".b).format
    assert_equal :flac, detect("a.bin", "fLaC\x00\x00\x00\x22".b).format
  end

  def test_categorizes_executables_separately
    assert_equal :executable, detect("a.bin", "\x7FELF\x02\x01\x01\x00".b).category
    assert_equal :executable, detect("a.txt", "#!/bin/sh\necho hi\n").category
  end

  def test_identifies_text_shapes
    assert_equal :text, detect("a.bin", "just some words\n").format
    assert_equal :json, detect("a.bin", %({"key": "value"})).format
    assert_equal :xml, detect("a.bin", "<?xml version=\"1.0\"?><root/>").format
    assert_equal :svg, detect("a.bin", "<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>").format
  end

  def test_reports_empty_files
    assert_equal :empty, detect("a.bin", "").format
  end

  def test_a_script_shebang_is_shown_sanitized
    detection = detect("a.sh", "#!/bin/sh\e[31m\necho hi\n")
    refute_includes detection.description, "\e"
    assert_includes detection.description, "\\x1B"
  end

  def test_flags_an_extension_that_disagrees_with_the_content
    file = write("sneaky.mp3", "\x89PNG\r\n\x1A\n".b)
    assert TypeDetector.extension_mismatch?(file, TypeDetector.detect(file))
  end

  def test_accepts_a_matching_extension
    file = write("real.png", "\x89PNG\r\n\x1A\n".b)
    refute TypeDetector.extension_mismatch?(file, TypeDetector.detect(file))
  end

  def test_does_not_flag_extensions_that_share_a_format_family
    file = write("sound.ogg", "OggS\x00\x02OpusHead".b)
    refute TypeDetector.extension_mismatch?(file, TypeDetector.detect(file))
  end

  def test_does_not_follow_a_symlink_when_reading_the_header
    File.symlink(write("real.txt", "content\n"), path("link"))
    assert_nil TypeDetector.read_header(path("link"))
  end
end
