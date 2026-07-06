# frozen_string_literal: true

module FileOrganizer
  module Metadata
    # Minimal, defensive TIFF/EXIF reader in pure Ruby.
    #
    # Only whitelisted tags are decoded, every offset is bounds-checked
    # against the in-memory buffer, IFD entry counts are capped, and only the
    # two known sub-IFDs (EXIF and GPS) are followed — so a crafted file can
    # neither read out of bounds nor send the parser into a loop.
    class ExifParser
      TYPE_SIZES = { 1 => 1, 2 => 1, 3 => 2, 4 => 4, 5 => 8, 6 => 1,
                     7 => 1, 8 => 2, 9 => 4, 10 => 8, 11 => 4, 12 => 8 }.freeze
      MAX_IFD_ENTRIES = 256
      MAX_VALUE_COUNT = 65_536

      IFD0_TAGS = {
        0x0100 => "Width",
        0x0101 => "Height",
        0x010F => "Camera make",
        0x0110 => "Camera model",
        0x0112 => "Orientation",
        0x0131 => "Software",
        0x0132 => "Modified (EXIF)",
        0x8769 => :exif_ifd,
        0x8825 => :gps_ifd
      }.freeze

      EXIF_TAGS = {
        0x829A => "Exposure time",
        0x829D => "Aperture",
        0x8827 => "ISO",
        0x9003 => "Taken",
        0x9209 => "Flash",
        0x920A => "Focal length",
        0xA002 => "Pixel width",
        0xA003 => "Pixel height",
        0xA430 => "Camera owner",
        0xA431 => "Serial number"
      }.freeze

      GPS_TAGS = { 1 => :lat_ref, 2 => :lat, 3 => :lon_ref, 4 => :lon,
                   5 => :alt_ref, 6 => :alt }.freeze

      ORIENTATIONS = {
        1 => "normal", 2 => "mirrored", 3 => "rotated 180°",
        4 => "mirrored, rotated 180°", 5 => "mirrored, rotated 90° CCW",
        6 => "rotated 90° CW", 7 => "mirrored, rotated 90° CW",
        8 => "rotated 90° CCW"
      }.freeze

      def initialize(tiff_data)
        @data = tiff_data.to_s.b
        @fields = {}
        @gps = {}
      end

      def parse
        order = @data.byteslice(0, 2)
        return {} unless %w[II MM].include?(order)

        @little_endian = (order == "II")
        return {} unless u16(2) == 42

        parse_ifd(u32(4), IFD0_TAGS)
        add_gps_fields
        @fields
      end

      private

      def parse_ifd(offset, table)
        return if offset.nil?

        count = u16(offset)
        return if count.nil?

        [count, MAX_IFD_ENTRIES].min.times do |i|
          parse_entry(offset + 2 + (i * 12), table)
        end
      end

      def parse_entry(entry_offset, table)
        label = table[u16(entry_offset)]
        return if label.nil?

        type = u16(entry_offset + 2)
        count = u32(entry_offset + 4)
        return if type.nil? || count.nil? || count > MAX_VALUE_COUNT

        value = read_value(type, count, entry_offset + 8)
        return if value.nil?

        case label
        when :exif_ifd then parse_ifd(scalar(value), EXIF_TAGS)
        when :gps_ifd then parse_gps(scalar(value))
        else
          text = present(label, value)
          @fields[label] = text unless text.nil? || @fields.key?(label)
        end
      end

      def parse_gps(offset)
        return if offset.nil?

        count = u16(offset)
        return if count.nil?

        [count, MAX_IFD_ENTRIES].min.times do |i|
          base = offset + 2 + (i * 12)
          key = GPS_TAGS[u16(base)]
          next if key.nil?

          type = u16(base + 2)
          n = u32(base + 4)
          next if type.nil? || n.nil? || n > 16

          value = read_value(type, n, base + 8)
          @gps[key] = value unless value.nil?
        end
      end

      def add_gps_fields
        lat = to_degrees(@gps[:lat])
        lon = to_degrees(@gps[:lon])
        if lat && lon
          lat = -lat if @gps[:lat_ref].to_s.start_with?("S")
          lon = -lon if @gps[:lon_ref].to_s.start_with?("W")
          @fields["GPS location"] = format("%.6f, %.6f (privacy-sensitive)", lat, lon)
        end

        altitude = scalar(@gps[:alt])
        return unless altitude.is_a?(Numeric)

        below = scalar(@gps[:alt_ref]) == 1
        @fields["GPS altitude"] = format("%.1f m%s", altitude, below ? " below sea level" : "")
      end

      def to_degrees(value)
        return value if value.is_a?(Numeric)
        return nil unless value.is_a?(Array) && value.size >= 3 && value.all?(Numeric)

        value[0] + (value[1] / 60.0) + (value[2] / 3600.0)
      end

      def read_value(type, count, value_field_offset)
        unit = TYPE_SIZES[type]
        return nil if unit.nil?

        total = unit * count
        data_offset = total <= 4 ? value_field_offset : u32(value_field_offset)
        raw = Binary.slice(@data, data_offset, total)
        return nil if raw.nil?

        decode(type, count, raw)
      end

      def decode(type, count, raw)
        case type
        when 2 # ASCII
          raw.byteslice(0, count).to_s[/\A[^\0]*/].to_s
             .force_encoding(Encoding::UTF_8).scrub("?").strip
        when 1, 6, 7 # byte types
          collapse(raw.unpack("C*"))
        when 3, 8 # 16-bit
          collapse(raw.unpack(@little_endian ? "v*" : "n*"))
        when 4, 9 # 32-bit
          collapse(raw.unpack(@little_endian ? "V*" : "N*"))
        when 5, 10 # rationals
          ints = raw.unpack(@little_endian ? "V*" : "N*")
          values = ints.each_slice(2).map do |numerator, denominator|
            denominator.to_i.zero? ? 0.0 : numerator.to_f / denominator
          end
          collapse(values)
        end
      end

      def collapse(values)
        values.size == 1 ? values.first : values
      end

      def scalar(value)
        value.is_a?(Array) ? value.first : value
      end

      def present(label, value)
        case label
        when "Orientation" then ORIENTATIONS[scalar(value)]
        when "Exposure time" then exposure(scalar(value))
        when "Aperture" then scalar(value).is_a?(Numeric) ? format("f/%.1f", scalar(value)) : nil
        when "Focal length" then scalar(value).is_a?(Numeric) ? format("%.1f mm", scalar(value)) : nil
        when "Flash" then flash(scalar(value))
        else
          stringify(value)
        end
      end

      def exposure(value)
        return nil unless value.is_a?(Numeric) && value.positive?

        value < 1 ? "1/#{(1.0 / value).round} s" : "#{value} s"
      end

      def flash(value)
        return nil unless value.is_a?(Integer)

        value.anybits?(1) ? "fired" : "did not fire"
      end

      def stringify(value)
        text = value.is_a?(Array) ? value.join(", ") : value.to_s
        text = text.strip
        text.empty? ? nil : text
      end

      def u16(offset)
        @little_endian ? Binary.u16le(@data, offset) : Binary.u16be(@data, offset)
      end

      def u32(offset)
        @little_endian ? Binary.u32le(@data, offset) : Binary.u32be(@data, offset)
      end
    end
  end
end
