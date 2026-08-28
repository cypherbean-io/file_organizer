# frozen_string_literal: true

require_relative "helper"

class TestPhotoMetadata < Minitest::Test
  include OrganizerTest

  def png(width, height, depth: 8, color: 2)
    header = [width, height, depth, color, 0, 0, 0].pack("NNC5")
    "\x89PNG\r\n\x1A\n".b + [header.bytesize].pack("N") + "IHDR" + header +
      [0].pack("N") # CRC, not checked
  end

  def test_reads_png_dimensions_and_colour
    fields = Metadata::Photo.extract(write("a.png", png(1600, 1200)), :png)

    assert_equal "1600 × 1200 px", fields["Dimensions"]
    assert_equal "1.9 MP", fields["Megapixels"]
    assert_equal "8-bit RGB", fields["Color"]
  end

  def test_reads_gif_dimensions
    gif = "GIF89a".b + [4, 3].pack("vv") + "\x00\x00\x00\x3B".b
    assert_equal "4 × 3 px", Metadata::Photo.extract(write("a.gif", gif), :gif)["Dimensions"]
  end

  def test_reads_jpeg_dimensions_from_the_frame_header
    sof = "\xFF\xC0".b + [11].pack("n") + [8, 480, 640].pack("Cnn")
    jpeg = "\xFF\xD8".b + sof + "\xFF\xD9".b
    assert_equal "640 × 480 px", Metadata::Photo.extract(write("a.jpg", jpeg), :jpeg)["Dimensions"]
  end

  def test_truncated_files_yield_no_metadata_rather_than_raising
    assert_empty Metadata::Photo.extract(write("a.png", "\x89PNG".b), :png)
    assert_empty Metadata::Photo.extract(write("a.gif", "GIF8".b), :gif)
    assert_empty Metadata::Photo.extract(write("a.jpg", "\xFF\xD8".b), :jpeg)
  end

  # Regression: the marker scan used one read(2) per byte with no cap, so a
  # single large file with no further markers took tens of seconds.
  def test_a_jpeg_with_no_further_markers_is_not_scanned_to_the_end
    body = "\xFF\xD8\xFF\xE0".b + [16].pack("n") + ("A".b * 14) + ("A".b * (8 * 1024 * 1024))
    file = write("huge.jpg", body)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Metadata::Photo.extract(file, :jpeg)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :<, 2.0, "marker scan is not bounded"
  end

  def test_a_jpeg_that_is_all_fill_bytes_is_not_scanned_to_the_end
    file = write("fill.jpg", "\xFF\xD8".b + ("\xFF".b * (8 * 1024 * 1024)))

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Metadata::Photo.extract(file, :jpeg)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :<, 2.0, "fill-byte run is not bounded"
  end

  def test_svg_values_are_sanitized_before_display
    svg = %(<svg width="10\e[31m" height="20" viewBox="0 0 10 20"></svg>)
    fields = Metadata::Photo.extract(write("a.svg", svg), :svg)

    refute_includes fields["Declared size"], "\e"
    assert_equal "0 0 10 20", fields["View box"]
  end
end

class TestAudioMetadata < Minitest::Test
  include OrganizerTest

  def test_reads_wave_stream_details
    fmt = [1, 1, 8000, 16_000, 2, 16].pack("vvVVvv")
    data = "\x00".b * 16_000
    wav = "RIFF".b + [36 + data.bytesize].pack("V") + "WAVE" +
          "fmt " + [fmt.bytesize].pack("V") + fmt +
          "data" + [data.bytesize].pack("V") + data
    fields = Metadata::Audio.extract(write("a.wav", wav), :wav)

    assert_equal "PCM (uncompressed)", fields["Codec"]
    assert_equal 1, fields["Channels"]
    assert_equal "8000 Hz", fields["Sample rate"]
    assert_equal "16-bit", fields["Bit depth"]
    assert_equal "0:01", fields["Duration"]
  end

  # METADATA_BLOCK_HEADER: last-block flag and type in one byte, then the
  # payload size as a 24-bit big-endian integer.
  def flac_block(type, payload, last: false)
    size = payload.bytesize
    [last ? type | 0x80 : type, size >> 16, size & 0xFFFF].pack("Ccn") + payload
  end

  def test_reads_flac_streaminfo_and_vorbis_comments
    packed = (44_100 << 44) | ((2 - 1) << 41) | ((16 - 1) << 36) | 132_300
    streaminfo = ("\x00".b * 10) + [packed].pack("Q>") + ("\x00".b * 16)

    comment = "TITLE=Test Track"
    vorbis = [0].pack("V") + [1].pack("V") + [comment.bytesize].pack("V") + comment

    flac = "fLaC".b + flac_block(0, streaminfo) + flac_block(4, vorbis, last: true)

    fields = Metadata::Audio.extract(write("a.flac", flac), :flac)

    assert_equal "FLAC (lossless)", fields["Codec"]
    assert_equal "44100 Hz", fields["Sample rate"]
    assert_equal 2, fields["Channels"]
    assert_equal "0:03", fields["Duration"]
    assert_equal "Test Track", fields["Title"]
  end

  def test_finds_an_mpeg_frame_after_leading_junk
    frame = [0xFF, 0xFB, 0x90, 0x00].pack("C4")
    mp3 = ("\x00".b * 4096) + frame + ("\x00".b * 1024)
    fields = Metadata::Audio.extract(write("a.mp3", mp3), :mp3)

    assert_equal "MPEG-1 Layer III (MP3)", fields["Codec"]
    assert_equal "44100 Hz", fields["Sample rate"]
    assert_equal "128 kbps", fields["Bitrate"]
  end

  def test_corrupt_audio_yields_no_metadata_rather_than_raising
    assert_empty Metadata::Audio.extract(write("a.wav", "RIFF".b), :wav)
    assert_empty Metadata::Audio.extract(write("a.flac", "fLaC".b), :flac)
    assert_empty Metadata::Audio.extract(write("a.mp3", "\x00".b * 32), :mp3)
  end

  def test_id3_tag_text_is_sanitized_before_display
    body = "\x00".b + "Song\e[31mName"
    frame = "TIT2" + [body.bytesize].pack("N") + "\x00\x00".b + body
    tag = "ID3\x03\x00\x00".b + [0, 0, 0, frame.bytesize].pack("C4") + frame
    fields = Metadata::Audio.extract(write("a.mp3", tag + ("\x00".b * 64)), :mp3)

    assert_equal "Song\e[31mName", fields["Title"]
    refute_includes Console.safe(fields["Title"]), "\e"
  end
end

class TestExifParser < Minitest::Test
  include OrganizerTest

  # Little-endian TIFF header with one IFD holding a single ASCII tag.
  def tiff_with_make(value)
    padded = value + "\x00"
    entry = [0x010F, 2, padded.bytesize, 26].pack("vvVV")
    "II*\x00".b + [8].pack("V") + [1].pack("v") + entry + [0].pack("V") + padded
  end

  def test_reads_a_whitelisted_tag
    assert_equal "TestCam", Metadata::ExifParser.new(tiff_with_make("TestCam")).parse["Camera make"]
  end

  def test_rejects_data_that_is_not_tiff
    assert_empty Metadata::ExifParser.new("not tiff at all").parse
    assert_empty Metadata::ExifParser.new("").parse
  end

  def test_an_offset_past_the_end_of_the_buffer_is_ignored
    entry = [0x010F, 2, 64, 100_000].pack("vvVV")
    data = "II*\x00".b + [8].pack("V") + [1].pack("v") + entry + [0].pack("V")
    assert_empty Metadata::ExifParser.new(data).parse
  end
end
