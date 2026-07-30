# frozen_string_literal: true

module FileOrganizer
  module Gui
    # Turns FileInfo objects and metadata hashes into the plain data the
    # browser receives.
    #
    # Every string that leaves this module passes through Console.safe: file
    # names and metadata tags are untrusted, they may not even be valid UTF-8
    # (which JSON cannot represent), and control characters have no business
    # reaching the page.
    module Presenter
      # Formats served for in-page preview, and nothing else. Deliberately
      # absent: SVG and PDF (documents that could carry script), plus TIFF and
      # HEIC, which browsers cannot decode anyway. Nothing scriptable is ever
      # served to the page as a file.
      IMAGE_TYPES = {
        jpeg: "image/jpeg", png: "image/png", gif: "image/gif",
        bmp: "image/bmp", webp: "image/webp"
      }.freeze

      AUDIO_TYPES = {
        mp3: "audio/mpeg", wav: "audio/wav", flac: "audio/flac",
        ogg: "audio/ogg", opus: "audio/ogg", m4a: "audio/mp4", aiff: "audio/aiff"
      }.freeze

      VIDEO_TYPES = {
        mp4: "video/mp4", matroska: "video/webm",
        quicktime: "video/quicktime", avi: "video/x-msvideo"
      }.freeze

      module_function

      def content_type(format)
        IMAGE_TYPES[format] || AUDIO_TYPES[format] || VIDEO_TYPES[format]
      end

      # "image", "audio", "video" — what the page can render inline — or nil.
      def media_kind(info)
        return nil unless info.regular?

        format = info.content_format
        return "image" if IMAGE_TYPES.key?(format)
        return "audio" if AUDIO_TYPES.key?(format)
        return "video" if VIDEO_TYPES.key?(format)

        nil
      end

      def summary(info)
        {
          "id" => Gui.encode_id(info.name),
          "name" => Console.safe(info.name),
          "size" => info.size,
          "modified" => info.mtime.to_i,
          "category" => category(info),
          "format" => (info.content_format || :none).to_s,
          "kind" => Console.safe(info.kind),
          "hidden" => info.hidden?,
          "symlink" => info.symlink?,
          "executable" => info.executable_bit?,
          "mismatch" => info.extension_mismatch?,
          "openable" => info.openable?,
          "textual" => info.textual?,
          "media" => media_kind(info)
        }
      end

      def detail(info)
        summary(info).merge(
          "fields" => info.rows.map { |label, value| field(label, value) },
          "sections" => sections(info)
        )
      end

      def category(info)
        return "link" if info.symlink?

        (info.category || :other).to_s
      end

      def sections(info)
        return [] unless info.regular?

        case info.category
        when :photo then [section("Photo metadata", Metadata::Photo.extract(info.path, info.content_format))]
        when :audio then [section("Audio metadata", Metadata::Audio.extract(info.path, info.content_format))]
        else []
        end
      end

      def section(title, fields)
        { "title" => title, "fields" => fields.map { |label, value| field(label, value) } }
      end

      def field(label, value)
        { "label" => Console.safe(label), "value" => Console.safe(value) }
      end
    end
  end
end
