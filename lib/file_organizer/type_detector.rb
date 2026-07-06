# frozen_string_literal: true

module FileOrganizer
  # Identifies file types by content (magic bytes / file signatures) rather
  # than trusting the file extension. The extension is only used afterwards
  # to warn the user when it does not match what the file actually contains.
  module TypeDetector
    Detection = Struct.new(:format, :description, :category, :textual, keyword_init: true) do
      def textual?
        !!textual
      end
    end

    HEADER_BYTES = 8192

    # Formats that may legitimately share an extension family.
    EQUIVALENT_FORMATS = [
      %i[ogg opus],
      %i[mp4 m4a],
      %i[zip office_document],
      %i[text script json xml svg]
    ].freeze

    EXTENSION_FORMATS = {
      ".jpg" => :jpeg, ".jpeg" => :jpeg, ".png" => :png, ".gif" => :gif,
      ".bmp" => :bmp, ".tif" => :tiff, ".tiff" => :tiff, ".webp" => :webp,
      ".heic" => :heic, ".heif" => :heic, ".svg" => :svg,
      ".mp3" => :mp3, ".wav" => :wav, ".flac" => :flac, ".ogg" => :ogg,
      ".opus" => :opus, ".m4a" => :m4a, ".aif" => :aiff, ".aiff" => :aiff,
      ".mid" => :midi, ".midi" => :midi,
      ".mp4" => :mp4, ".mov" => :quicktime, ".mkv" => :matroska,
      ".webm" => :matroska, ".avi" => :avi,
      ".pdf" => :pdf, ".zip" => :zip, ".gz" => :gzip, ".bz2" => :bzip2,
      ".xz" => :xz, ".7z" => :sevenzip, ".rar" => :rar, ".tar" => :tar,
      ".sqlite" => :sqlite, ".db" => :sqlite,
      ".exe" => :windows_executable, ".dll" => :windows_executable
    }.freeze

    module_function

    def detect(path)
      header = read_header(path)
      return unknown("file could not be read") if header.nil?
      return Detection.new(format: :empty, description: "Empty file (0 bytes)",
                           category: :other, textual: false) if header.empty?

      by_signature(header) || by_text(header) || unknown
    end

    # True when the file's extension claims a known format that differs from
    # what the content actually is — a classic disguise for malicious files.
    def extension_mismatch?(path, detection)
      return false if detection.nil? || detection.format == :unknown
      expected = EXTENSION_FORMATS[File.extname(path).downcase]
      return false if expected.nil? || expected == detection.format

      EQUIVALENT_FORMATS.none? { |group| group.include?(expected) && group.include?(detection.format) }
    end

    def unknown(reason = nil)
      description = reason ? "Unknown (#{reason})" : "Unknown binary data"
      Detection.new(format: :unknown, description: description, category: :binary, textual: false)
    end

    def read_header(path)
      File.open(path, "rb") { |f| f.read(HEADER_BYTES) } || ""
    rescue SystemCallError, IOError
      nil
    end

    def by_signature(h)
      photo_signature(h) || audio_signature(h) || video_signature(h) ||
        archive_signature(h) || executable_signature(h) || document_signature(h)
    end

    def photo_signature(h)
      return build(:jpeg, "JPEG image", :photo) if h.start_with?("\xFF\xD8\xFF".b)
      return build(:png, "PNG image", :photo) if h.start_with?("\x89PNG\r\n\x1A\n".b)
      return build(:gif, "GIF image (#{h.byteslice(3, 3)})", :photo) if h.start_with?("GIF87a") || h.start_with?("GIF89a")
      return build(:bmp, "BMP image", :photo) if h.start_with?("BM") && h.bytesize > 26
      return build(:tiff, "TIFF image", :photo) if h.start_with?("II*\x00".b) || h.start_with?("MM\x00*".b)
      return build(:webp, "WebP image", :photo) if riff?(h, "WEBP")
      return build(:heic, "HEIC/HEIF image", :photo) if ftyp?(h, %w[heic heix heim heis hevc hevx mif1 msf1])

      nil
    end

    def audio_signature(h)
      return build(:flac, "FLAC audio (lossless)", :audio) if h.start_with?("fLaC")
      return build(:wav, "WAVE audio", :audio) if riff?(h, "WAVE")
      return build(:aiff, "AIFF audio", :audio) if h.start_with?("FORM") && %w[AIFF AIFC].include?(h.byteslice(8, 4))
      return build(:midi, "MIDI sequence", :audio) if h.start_with?("MThd")
      return build(:m4a, "MPEG-4 audio (M4A)", :audio) if ftyp?(h, %w[M4A M4B])

      if h.start_with?("OggS")
        return build(:opus, "Opus audio (Ogg container)", :audio) if h.include?("OpusHead")

        return build(:ogg, "Ogg audio", :audio)
      end
      return build(:mp3, "MP3 audio (ID3 tagged)", :audio) if h.start_with?("ID3")
      return build(:mp3, "MPEG audio (MP3)", :audio) if mpeg_audio_sync?(h)

      nil
    end

    def video_signature(h)
      return build(:avi, "AVI video", :video) if riff?(h, "AVI ")
      return build(:matroska, "Matroska/WebM video", :video) if h.start_with?("\x1A\x45\xDF\xA3".b)
      return build(:quicktime, "QuickTime video", :video) if ftyp?(h, %w[qt])
      return build(:mp4, "MPEG-4 video", :video) if h.byteslice(4, 4) == "ftyp"

      nil
    end

    def archive_signature(h)
      if h.start_with?("PK\x03\x04".b)
        return build(:office_document, "Office Open XML document (ZIP)", :document) if h.include?("[Content_Types].xml")

        return build(:zip, "ZIP archive", :archive)
      end
      return build(:gzip, "gzip compressed data", :archive) if h.start_with?("\x1F\x8B".b)
      return build(:bzip2, "bzip2 compressed data", :archive) if h.start_with?("BZh")
      return build(:xz, "xz compressed data", :archive) if h.start_with?("\xFD7zXZ\x00".b)
      return build(:sevenzip, "7-Zip archive", :archive) if h.start_with?("7z\xBC\xAF\x27\x1C".b)
      return build(:rar, "RAR archive", :archive) if h.start_with?("Rar!\x1A\x07".b)
      return build(:tar, "tar archive", :archive) if h.byteslice(257, 5) == "ustar"

      nil
    end

    def executable_signature(h)
      return build(:elf, "ELF executable/library", :executable) if h.start_with?("\x7FELF".b)
      return build(:windows_executable, "Windows executable (PE)", :executable) if h.start_with?("MZ")

      mach_o = ["\xFE\xED\xFA\xCE".b, "\xCE\xFA\xED\xFE".b, "\xFE\xED\xFA\xCF".b, "\xCF\xFA\xED\xFE".b]
      return build(:mach_o, "Mach-O executable/library", :executable) if mach_o.any? { |m| h.start_with?(m) }
      return build(:mach_o_fat, "Mach-O universal binary or Java class", :executable) if h.start_with?("\xCA\xFE\xBA\xBE".b)

      nil
    end

    def document_signature(h)
      return build(:pdf, "PDF document", :document) if h.start_with?("%PDF-")
      return build(:sqlite, "SQLite 3 database", :data) if h.start_with?("SQLite format 3\x00".b)

      nil
    end

    def by_text(h)
      return nil if h.include?("\x00")

      text = trimmed_utf8(h)
      return nil unless text.valid_encoding? || mostly_printable_ascii?(h)

      if text.start_with?("#!")
        interpreter = Console.safe(text.lines.first.to_s.chomp)
        return build(:script, "Script (#{interpreter})", :executable, textual: true)
      end

      stripped = text.valid_encoding? ? text.lstrip : ""
      if stripped.start_with?("<?xml", "<svg", "<!DOCTYPE", "<")
        return build(:svg, "SVG image (XML text)", :photo, textual: true) if stripped.match?(/<svg[\s>]/i)

        return build(:xml, "XML/HTML text", :text, textual: true)
      end
      return build(:json, "JSON text", :text, textual: true) if stripped.start_with?("{", "[")

      build(:text, "Plain text (UTF-8)", :text, textual: true)
    end

    def build(format, description, category, textual: false)
      Detection.new(format: format, description: description, category: category, textual: textual)
    end

    def riff?(h, form)
      h.start_with?("RIFF") && h.byteslice(8, 4) == form
    end

    def ftyp?(h, brands)
      return false unless h.byteslice(4, 4) == "ftyp"

      brand = h.byteslice(8, 4).to_s.strip
      brands.any? { |b| brand.casecmp?(b) }
    end

    def mpeg_audio_sync?(h)
      return false if h.bytesize < 4

      h.getbyte(0) == 0xFF && (h.getbyte(1) & 0xE0) == 0xE0 &&
        ((h.getbyte(1) >> 1) & 0x3) != 0 && ((h.getbyte(1) >> 3) & 0x3) != 1
    end

    # Drops up to three trailing bytes so a multi-byte UTF-8 character cut in
    # half by the fixed-size header read does not mark real text as binary.
    def trimmed_utf8(h)
      text = h.dup.force_encoding(Encoding::UTF_8)
      3.times do
        break if text.valid_encoding? || text.empty?

        text = text.byteslice(0, text.bytesize - 1).force_encoding(Encoding::UTF_8)
      end
      text
    end

    def mostly_printable_ascii?(h)
      printable = h.count("\t\r\n\x20-\x7E")
      printable >= h.bytesize * 0.9
    end
  end
end
