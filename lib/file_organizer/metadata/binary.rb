# frozen_string_literal: true

module FileOrganizer
  module Metadata
    # Bounds-checked binary readers shared by the metadata parsers. Every
    # reader returns nil instead of raising when the requested bytes fall
    # outside the buffer, so truncated or corrupt files cannot crash parsing.
    module Binary
      module_function

      def u16le(data, offset)
        unpack(data, offset, 2, "v")
      end

      def u16be(data, offset)
        unpack(data, offset, 2, "n")
      end

      def u24le(data, offset)
        bytes = slice(data, offset, 3)
        return nil if bytes.nil?

        bytes.getbyte(0) | (bytes.getbyte(1) << 8) | (bytes.getbyte(2) << 16)
      end

      def u24be(data, offset)
        bytes = slice(data, offset, 3)
        return nil if bytes.nil?

        (bytes.getbyte(0) << 16) | (bytes.getbyte(1) << 8) | bytes.getbyte(2)
      end

      def u32le(data, offset)
        unpack(data, offset, 4, "V")
      end

      def u32be(data, offset)
        unpack(data, offset, 4, "N")
      end

      def u64le(data, offset)
        unpack(data, offset, 8, "Q<")
      end

      def u64be(data, offset)
        unpack(data, offset, 8, "Q>")
      end

      def slice(data, offset, length)
        return nil if data.nil? || offset.nil? || offset.negative?

        piece = data.byteslice(offset, length)
        piece && piece.bytesize == length ? piece : nil
      end

      def unpack(data, offset, length, directive)
        slice(data, offset, length)&.unpack1(directive)
      end

      def duration_label(seconds)
        return nil unless seconds.is_a?(Numeric) && seconds.finite? && seconds.positive?

        total = seconds.round
        if total >= 3600
          format("%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        else
          format("%d:%02d", total / 60, total % 60)
        end
      end
    end
  end
end
