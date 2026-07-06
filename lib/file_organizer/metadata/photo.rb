# frozen_string_literal: true

module FileOrganizer
  module Metadata
    # Photo metadata extraction, implemented in pure Ruby with bounded reads:
    # only header/metadata segments are loaded, never the whole image.
    module Photo
      MAX_METADATA_BYTES = 1 << 20 # 1 MiB cap on any metadata segment

      SOF_MARKERS = [0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7,
                     0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF].freeze

      PNG_COLOR_TYPES = {
        0 => "grayscale", 2 => "RGB", 3 => "indexed color",
        4 => "grayscale + alpha", 6 => "RGB + alpha"
      }.freeze

      module_function

      def extract(path, format)
        case format
        when :jpeg then jpeg(path)
        when :png then png(path)
        when :gif then gif(path)
        when :bmp then bmp(path)
        when :tiff then tiff(path)
        when :webp then webp(path)
        when :svg then svg(path)
        else {}
        end
      rescue StandardError
        { "Error" => "metadata could not be parsed (file may be corrupt)" }
      end

      def jpeg(path)
        fields = {}
        exif = nil
        File.open(path, "rb") do |io|
          return {} unless io.read(2) == "\xFF\xD8".b

          while (marker = next_marker(io))
            break if marker == 0xD9 || marker == 0xDA # EOI / start of image data
            next if marker == 0x01 || (0xD0..0xD8).cover?(marker) # no payload

            length = io.read(2)&.unpack1("n")
            break if length.nil? || length < 2

            payload_length = length - 2
            if marker == 0xE1 && exif.nil?
              payload = read_bounded(io, payload_length)
              exif = payload.byteslice(6..) if payload&.start_with?("Exif\x00\x00".b)
            elsif SOF_MARKERS.include?(marker) && !fields.key?("Dimensions")
              payload = read_bounded(io, payload_length, cap: 8)
              if payload && payload.bytesize >= 5
                _precision, height, width = payload.unpack("Cnn")
                add_dimensions(fields, width, height)
              end
            else
              io.seek(payload_length, IO::SEEK_CUR)
            end
          end
        end

        merge_exif(fields, exif)
        fields
      end

      def png(path)
        header = File.open(path, "rb") { |f| f.read(33) }
        return {} unless header&.bytesize == 33 && header.byteslice(12, 4) == "IHDR"

        width, height, depth, color, _compression, _filter, interlace =
          header.byteslice(16, 13).unpack("NNC5")
        fields = {}
        add_dimensions(fields, width, height)
        fields["Color"] = "#{depth}-bit #{PNG_COLOR_TYPES.fetch(color, "unknown")}"
        fields["Interlaced"] = "yes" if interlace == 1
        fields
      end

      def gif(path)
        header = File.open(path, "rb") { |f| f.read(13) }
        return {} unless header&.bytesize == 13

        _signature, width, height = header.unpack("a6vv")
        fields = {}
        add_dimensions(fields, width, height)
        fields["Version"] = header.byteslice(3, 3)
        fields
      end

      def bmp(path)
        header = File.open(path, "rb") { |f| f.read(26) }
        return {} unless header&.bytesize == 26

        width, height = header.byteslice(18, 8).unpack("l<l<")
        fields = {}
        add_dimensions(fields, width, height.abs)
        fields
      end

      def tiff(path)
        data = File.open(path, "rb") { |f| f.read(MAX_METADATA_BYTES) }
        exif_fields = ExifParser.new(data).parse
        fields = {}
        width = exif_fields.delete("Width")
        height = exif_fields.delete("Height")
        add_dimensions(fields, width.to_i, height.to_i) if width && height
        fields.merge!(exif_fields)
        fields
      end

      def webp(path)
        header = File.open(path, "rb") { |f| f.read(30) }
        return {} unless header&.bytesize == 30

        fields = {}
        case header.byteslice(12, 4)
        when "VP8X"
          width = Binary.u24le(header, 24).to_i + 1
          height = Binary.u24le(header, 27).to_i + 1
          add_dimensions(fields, width, height)
          fields["Variant"] = "extended (VP8X)"
        when "VP8 "
          width = Binary.u16le(header, 26).to_i & 0x3FFF
          height = Binary.u16le(header, 28).to_i & 0x3FFF
          add_dimensions(fields, width, height)
          fields["Variant"] = "lossy (VP8)"
        when "VP8L"
          bits = Binary.u32le(header, 21).to_i
          add_dimensions(fields, (bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1)
          fields["Variant"] = "lossless (VP8L)"
        end
        fields
      end

      def svg(path)
        header = File.open(path, "rb") { |f| f.read(4096) }.to_s
                     .force_encoding(Encoding::UTF_8).scrub("?")
        tag = header[/<svg[^>]*>/i]
        return {} if tag.nil?

        fields = {}
        width = tag[/\bwidth\s*=\s*["']([^"']+)["']/i, 1]
        height = tag[/\bheight\s*=\s*["']([^"']+)["']/i, 1]
        viewbox = tag[/\bviewBox\s*=\s*["']([^"']+)["']/i, 1]
        fields["Declared size"] = Console.safe("#{width} × #{height}") if width && height
        fields["View box"] = Console.safe(viewbox) if viewbox
        fields
      end

      def add_dimensions(fields, width, height)
        return unless width.to_i.positive? && height.to_i.positive?

        fields["Dimensions"] = "#{width} × #{height} px"
        megapixels = width.to_i * height.to_i / 1_000_000.0
        fields["Megapixels"] = format("%.1f MP", megapixels) if megapixels >= 0.1
      end

      def merge_exif(fields, exif)
        return if exif.nil?

        exif_fields = ExifParser.new(exif).parse
        if fields.key?("Dimensions")
          exif_fields.delete("Pixel width")
          exif_fields.delete("Pixel height")
        end
        exif_fields.delete("Width")
        exif_fields.delete("Height")
        fields.merge!(exif_fields) { |_key, existing, _new| existing }
      end

      # Reads up to +cap+ bytes of a segment and skips the remainder, so a
      # file claiming a huge metadata segment cannot exhaust memory.
      def read_bounded(io, length, cap: MAX_METADATA_BYTES)
        take = [length, cap].min
        data = io.read(take)
        io.seek(length - take, IO::SEEK_CUR) if length > take
        data
      end

      def next_marker(io)
        loop do
          byte = io.read(1)
          return nil if byte.nil?
          next unless byte == "\xFF".b

          code = io.read(1)
          code = io.read(1) while code == "\xFF".b
          return nil if code.nil?

          return code.unpack1("C")
        end
      end
    end
  end
end
