# frozen_string_literal: true

module FileOrganizer
  module Metadata
    # Audio metadata extraction in pure Ruby: ID3v1/v2, MPEG frame headers,
    # WAVE/AIFF chunks, FLAC STREAMINFO + Vorbis comments, Ogg Vorbis/Opus,
    # and MPEG-4 (M4A) atoms. All reads are bounded.
    module Audio
      MAX_TAG_BYTES = 1 << 20
      SYNC_BYTE = "\xFF".b.freeze
      MAX_TEXT_BYTES = 4096

      ID3V23_FRAMES = {
        "TIT2" => "Title", "TPE1" => "Artist", "TALB" => "Album",
        "TDRC" => "Year", "TYER" => "Year", "TRCK" => "Track",
        "TCON" => "Genre", "TPE2" => "Album artist", "TCOM" => "Composer"
      }.freeze

      ID3V22_FRAMES = {
        "TT2" => "Title", "TP1" => "Artist", "TAL" => "Album",
        "TYE" => "Year", "TRK" => "Track", "TCO" => "Genre"
      }.freeze

      ID3V1_GENRES = [
        "Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge",
        "Hip-Hop", "Jazz", "Metal", "New Age", "Oldies", "Other", "Pop", "R&B",
        "Rap", "Reggae", "Rock", "Techno", "Industrial", "Alternative", "Ska",
        "Death Metal", "Pranks", "Soundtrack", "Euro-Techno", "Ambient",
        "Trip-Hop", "Vocal", "Jazz+Funk", "Fusion", "Trance", "Classical",
        "Instrumental", "Acid", "House", "Game", "Sound Clip", "Gospel",
        "Noise", "Alternative Rock", "Bass", "Soul", "Punk", "Space",
        "Meditative", "Instrumental Pop", "Instrumental Rock", "Ethnic",
        "Gothic", "Darkwave", "Techno-Industrial", "Electronic", "Pop-Folk",
        "Eurodance", "Dream", "Southern Rock", "Comedy", "Cult", "Gangsta",
        "Top 40", "Christian Rap", "Pop/Funk", "Jungle", "Native American",
        "Cabaret", "New Wave", "Psychedelic", "Rave", "Showtunes", "Trailer",
        "Lo-Fi", "Tribal", "Acid Punk", "Acid Jazz", "Polka", "Retro",
        "Musical", "Rock & Roll", "Hard Rock"
      ].freeze

      VORBIS_FIELDS = {
        "TITLE" => "Title", "ARTIST" => "Artist", "ALBUM" => "Album",
        "DATE" => "Year", "GENRE" => "Genre", "TRACKNUMBER" => "Track",
        "ALBUMARTIST" => "Album artist", "COMPOSER" => "Composer"
      }.freeze

      MPEG1_L3_BITRATES = [nil, 32, 40, 48, 56, 64, 80, 96, 112, 128,
                           160, 192, 224, 256, 320].freeze
      MPEG2_L3_BITRATES = [nil, 8, 16, 24, 32, 40, 48, 56, 64, 80,
                           96, 112, 128, 144, 160].freeze
      SAMPLE_RATES = { 3 => [44_100, 48_000, 32_000],
                       2 => [22_050, 24_000, 16_000],
                       0 => [11_025, 12_000, 8_000] }.freeze

      module_function

      def extract(path, format)
        case format
        when :mp3 then mp3(path)
        when :wav then wav(path)
        when :flac then flac(path)
        when :ogg, :opus then ogg(path)
        when :m4a then m4a(path)
        when :aiff then aiff(path)
        else {}
        end
      rescue StandardError
        { "Error" => "metadata could not be parsed (file may be corrupt)" }
      end

      # --- MP3 -----------------------------------------------------------

      def mp3(path)
        fields = {}
        SafeFile.open(path) do |io|
          file_size = io.size
          tags, tag_bytes = id3v2(io)
          fields.merge!(tags)

          io.seek(tag_bytes, IO::SEEK_SET)
          frame = find_frame(io.read(65_536).to_s)
          v1 = read_id3v1(io)
          audio_bytes = file_size - tag_bytes - (v1 ? 128 : 0)

          add_mp3_stream_fields(fields, frame, audio_bytes) if frame
          v1&.each { |key, value| fields[key] = value unless fields.key?(key) }
        end
        fields
      end

      def add_mp3_stream_fields(fields, frame, audio_bytes)
        fields["Codec"] = frame[:codec]
        fields["Sample rate"] = "#{frame[:sample_rate]} Hz"
        fields["Channels"] = frame[:channels]
        if frame[:vbr_frames]
          seconds = frame[:vbr_frames] * frame[:samples_per_frame] / frame[:sample_rate].to_f
          fields["Duration"] = Binary.duration_label(seconds)
          if seconds.positive? && audio_bytes.positive?
            fields["Bitrate"] = format("~%d kbps (VBR)", (audio_bytes * 8 / seconds / 1000.0).round)
          end
        elsif frame[:bitrate]
          fields["Bitrate"] = "#{frame[:bitrate]} kbps"
          seconds = audio_bytes * 8.0 / (frame[:bitrate] * 1000)
          fields["Duration (estimated)"] = Binary.duration_label(seconds)
        end
      end

      def id3v2(io)
        io.seek(0, IO::SEEK_SET)
        header = io.read(10)
        return [{}, 0] unless header&.bytesize == 10 && header.start_with?("ID3")

        major = header.getbyte(3)
        size = syncsafe(header.byteslice(6, 4))
        return [{}, 0] if size.nil?

        tag = io.read([size, MAX_TAG_BYTES].min).to_s
        table = major == 2 ? ID3V22_FRAMES : ID3V23_FRAMES
        id_length = major == 2 ? 3 : 4
        head_length = major == 2 ? 6 : 10

        fields = {}
        pos = 0
        while pos + head_length <= tag.bytesize
          id = tag.byteslice(pos, id_length)
          break if id.nil? || id.getbyte(0).zero?

          frame_size =
            case major
            when 2 then Binary.u24be(tag, pos + 3)
            when 4 then syncsafe(tag.byteslice(pos + 4, 4))
            else Binary.u32be(tag, pos + 4)
            end
          break if frame_size.nil? || frame_size <= 0 || pos + head_length + frame_size > tag.bytesize

          body = tag.byteslice(pos + head_length, [frame_size, MAX_TEXT_BYTES].min)
          label = table[id]
          if label && !fields.key?(label)
            text = decode_id3_text(body)
            fields[label] = text if text
          elsif %w[APIC PIC].include?(id)
            fields["Embedded artwork"] = "yes"
          end
          pos += head_length + frame_size
        end
        [fields, size + 10]
      end

      def decode_id3_text(body)
        return nil if body.nil? || body.bytesize < 2

        text = body.byteslice(1..)
        decoded =
          case body.getbyte(0)
          when 0 then text.force_encoding(Encoding::ISO_8859_1).encode(Encoding::UTF_8)
          when 1 then text.force_encoding(Encoding::UTF_16).encode(Encoding::UTF_8)
          when 2 then text.force_encoding(Encoding::UTF_16BE).encode(Encoding::UTF_8)
          else text.force_encoding(Encoding::UTF_8)
          end
        cleaned = decoded.scrub("?").delete("\0").strip
        cleaned.empty? ? nil : cleaned
      rescue EncodingError
        nil
      end

      def syncsafe(bytes)
        return nil if bytes.nil? || bytes.bytesize < 4

        values = bytes.unpack("C4")
        return nil if values.any? { |b| b > 0x7F }

        values.reduce(0) { |acc, b| (acc << 7) | b }
      end

      def read_id3v1(io)
        return nil if io.size < 128

        io.seek(-128, IO::SEEK_END)
        block = io.read(128)
        return nil unless block&.start_with?("TAG")

        fields = {}
        { "Title" => block.byteslice(3, 30), "Artist" => block.byteslice(33, 30),
          "Album" => block.byteslice(63, 30), "Year" => block.byteslice(93, 4) }.each do |label, raw|
          text = raw.to_s.delete("\0").force_encoding(Encoding::ISO_8859_1)
                    .encode(Encoding::UTF_8).strip
          fields[label] = text unless text.empty?
        end
        if block.getbyte(125).zero? && block.getbyte(126).positive?
          fields["Track"] = block.getbyte(126).to_s
        end
        genre = ID3V1_GENRES[block.getbyte(127)]
        fields["Genre"] = genre if genre
        fields
      end

      # Finds the first valid MPEG frame header. String#index jumps straight
      # to each sync byte instead of testing all 64 KiB one byte at a time
      # from Ruby, which is the difference between a scan you notice and one
      # you do not.
      def find_frame(chunk)
        limit = chunk.bytesize - 4
        position = 0
        while position < limit
          position = chunk.index(SYNC_BYTE, position)
          break if position.nil? || position >= limit

          if (chunk.getbyte(position + 1) & 0xE0) == 0xE0
            frame = parse_frame_header(chunk, position)
            return frame if frame
          end
          position += 1
        end
        nil
      end

      def parse_frame_header(chunk, i)
        b1 = chunk.getbyte(i + 1)
        b2 = chunk.getbyte(i + 2)
        b3 = chunk.getbyte(i + 3)
        version_bits = (b1 >> 3) & 0x3 # 3 = MPEG-1, 2 = MPEG-2, 0 = MPEG-2.5
        layer_bits = (b1 >> 1) & 0x3   # 1 = Layer III
        return nil if version_bits == 1 || layer_bits != 1

        bitrate_index = (b2 >> 4) & 0xF
        rate_index = (b2 >> 2) & 0x3
        return nil if bitrate_index.zero? || bitrate_index == 0xF || rate_index == 3

        mpeg1 = version_bits == 3
        mode = (b3 >> 6) & 0x3
        mono = mode == 3
        version_name = { 3 => "MPEG-1", 2 => "MPEG-2", 0 => "MPEG-2.5" }[version_bits]

        frame = {
          codec: "#{version_name} Layer III (MP3)",
          bitrate: (mpeg1 ? MPEG1_L3_BITRATES : MPEG2_L3_BITRATES)[bitrate_index],
          sample_rate: SAMPLE_RATES.fetch(version_bits)[rate_index],
          channels: mono ? "1 (mono)" : "2 (#{%w[stereo joint-stereo dual-channel][mode]})",
          samples_per_frame: mpeg1 ? 1152 : 576
        }
        read_xing(chunk, i, frame, mpeg1: mpeg1, mono: mono)
        frame
      end

      def read_xing(chunk, frame_start, frame, mpeg1:, mono:)
        side_info = mpeg1 ? (mono ? 17 : 32) : (mono ? 9 : 17)
        offset = frame_start + 4 + side_info
        return unless %w[Xing Info].include?(chunk.byteslice(offset, 4))

        flags = Binary.u32be(chunk, offset + 4)
        return unless flags && flags.anybits?(1)

        frame[:vbr_frames] = Binary.u32be(chunk, offset + 8)
      end

      # --- WAVE ----------------------------------------------------------

      def wav(path)
        fields = {}
        SafeFile.open(path) do |io|
          riff = io.read(12)
          return {} unless riff&.bytesize == 12 && riff.start_with?("RIFF") &&
                           riff.byteslice(8, 4) == "WAVE"

          byte_rate = nil
          data_size = nil
          while (chunk = io.read(8)) && chunk.bytesize == 8
            chunk_id = chunk.byteslice(0, 4)
            chunk_size = Binary.u32le(chunk, 4)
            break if chunk_size.nil?

            if chunk_id == "fmt "
              fmt = io.read([chunk_size, 16].min).to_s
              io.seek(chunk_size - fmt.bytesize, IO::SEEK_CUR) if chunk_size > fmt.bytesize
              format_code, channels, sample_rate, rate, _block, bits = fmt.unpack("vvVVvv")
              byte_rate = rate
              fields["Codec"] = format_code == 1 ? "PCM (uncompressed)" : "WAVE format code #{format_code}"
              fields["Channels"] = channels
              fields["Sample rate"] = "#{sample_rate} Hz"
              fields["Bit depth"] = "#{bits}-bit" if bits
            else
              data_size = chunk_size if chunk_id == "data"
              io.seek(chunk_size, IO::SEEK_CUR)
            end
            io.seek(1, IO::SEEK_CUR) if chunk_size.odd?
          end

          if byte_rate&.positive? && data_size
            fields["Duration"] = Binary.duration_label(data_size / byte_rate.to_f)
          end
        end
        fields
      end

      # --- FLAC ----------------------------------------------------------

      def flac(path)
        fields = {}
        SafeFile.open(path) do |io|
          return {} unless io.read(4) == "fLaC"

          last = false
          until last
            header = io.read(4)
            break if header.nil? || header.bytesize < 4

            last = (header.getbyte(0) & 0x80).positive?
            type = header.getbyte(0) & 0x7F
            size = Binary.u24be(header, 1).to_i

            case type
            when 0 then read_flac_streaminfo(io, size, fields)
            when 4
              block = io.read([size, MAX_TAG_BYTES].min).to_s
              io.seek(size - block.bytesize, IO::SEEK_CUR) if size > block.bytesize
              vorbis_comments(block).each { |key, value| fields[key] = value unless fields.key?(key) }
            when 6
              fields["Embedded artwork"] = "yes"
              io.seek(size, IO::SEEK_CUR)
            else
              io.seek(size, IO::SEEK_CUR)
            end
          end
        end
        fields
      end

      def read_flac_streaminfo(io, size, fields)
        info = io.read([size, 34].min).to_s
        io.seek(size - info.bytesize, IO::SEEK_CUR) if size > info.bytesize
        packed = Binary.u64be(info, 10)
        return if packed.nil?

        sample_rate = packed >> 44
        channels = ((packed >> 41) & 0x7) + 1
        bits = ((packed >> 36) & 0x1F) + 1
        total_samples = packed & ((1 << 36) - 1)

        fields["Codec"] = "FLAC (lossless)"
        fields["Sample rate"] = "#{sample_rate} Hz"
        fields["Channels"] = channels
        fields["Bit depth"] = "#{bits}-bit"
        return unless sample_rate.positive? && total_samples.positive?

        fields["Duration"] = Binary.duration_label(total_samples / sample_rate.to_f)
      end

      def vorbis_comments(data)
        vendor_length = Binary.u32le(data, 0)
        return {} if vendor_length.nil? || vendor_length > data.bytesize

        pos = 4 + vendor_length
        count = Binary.u32le(data, pos)
        return {} if count.nil?

        pos += 4
        fields = {}
        [count, 64].min.times do
          length = Binary.u32le(data, pos)
          break if length.nil?

          pos += 4
          entry = data.byteslice(pos, [length, MAX_TEXT_BYTES].min).to_s
          pos += length
          key, value = entry.split("=", 2)
          next if key.nil? || value.nil?

          label = VORBIS_FIELDS[key.upcase]
          next if label.nil? || fields.key?(label)

          text = value.force_encoding(Encoding::UTF_8).scrub("?").strip
          fields[label] = text unless text.empty?
        end
        fields
      end

      # --- Ogg (Vorbis / Opus) -------------------------------------------

      def ogg(path)
        head = nil
        tail = nil
        SafeFile.open(path) do |io|
          head = io.read(8192).to_s
          tail_size = [io.size, 65_536].min
          io.seek(-tail_size, IO::SEEK_END)
          tail = io.read(tail_size).to_s
        end

        fields = {}
        sample_rate = nil
        preskip = 0
        opus = false

        if (i = head.index("\x01vorbis"))
          fields["Codec"] = "Vorbis (Ogg container)"
          fields["Channels"] = head.getbyte(i + 11)
          sample_rate = Binary.u32le(head, i + 12)
          fields["Sample rate"] = "#{sample_rate} Hz" if sample_rate
          if (c = head.index("\x03vorbis"))
            merge_missing(fields, vorbis_comments(head.byteslice(c + 7, head.bytesize)))
          end
        elsif (i = head.index("OpusHead"))
          opus = true
          sample_rate = 48_000
          fields["Codec"] = "Opus (Ogg container)"
          fields["Channels"] = head.getbyte(i + 9)
          preskip = Binary.u16le(head, i + 10).to_i
          original = Binary.u32le(head, i + 12)
          fields["Sample rate"] = "48000 Hz (decoded)#{original ? ", #{original} Hz original" : ""}"
          if (c = head.index("OpusTags"))
            merge_missing(fields, vorbis_comments(head.byteslice(c + 8, head.bytesize)))
          end
        else
          fields["Codec"] = "Ogg (unrecognized codec)"
        end

        add_ogg_duration(fields, tail, sample_rate, opus ? preskip : 0)
        fields
      end

      def add_ogg_duration(fields, tail, sample_rate, preskip)
        return unless sample_rate&.positive? && (j = tail.rindex("OggS"))

        granule = Binary.u64le(tail, j + 6)
        return unless granule && granule.positive? && granule < (1 << 62)

        fields["Duration"] = Binary.duration_label((granule - preskip) / sample_rate.to_f)
      end

      def merge_missing(fields, extra)
        extra.each { |key, value| fields[key] = value unless fields.key?(key) }
      end

      # --- MPEG-4 audio (M4A) ---------------------------------------------

      M4A_TAG_ATOMS = {
        "\xA9nam".b => "Title", "\xA9ART".b => "Artist", "\xA9alb".b => "Album",
        "\xA9day".b => "Year", "\xA9gen".b => "Genre", "aART" => "Album artist"
      }.freeze

      def m4a(path)
        head = SafeFile.read(path, 2 * MAX_TAG_BYTES).to_s
        fields = {}
        if head.byteslice(4, 4) == "ftyp"
          brand = head.byteslice(8, 4).to_s.strip
          fields["Container"] = "MPEG-4 (#{Console.safe(brand)})"
        end
        add_m4a_duration(head, fields)
        add_m4a_tags(head, fields)
        fields
      end

      def add_m4a_duration(head, fields)
        i = head.index("mvhd")
        return if i.nil?

        if head.getbyte(i + 4) == 1
          timescale = Binary.u32be(head, i + 24)
          duration = Binary.u64be(head, i + 28)
        else
          timescale = Binary.u32be(head, i + 16)
          duration = Binary.u32be(head, i + 20)
        end
        return unless timescale&.positive? && duration

        fields["Duration"] = Binary.duration_label(duration.to_f / timescale)
      end

      def add_m4a_tags(head, fields)
        ilst = head.index("ilst")
        return if ilst.nil?

        M4A_TAG_ATOMS.each do |atom, label|
          i = head.index(atom, ilst)
          next if i.nil? || head.byteslice(i + 8, 4) != "data"

          size = Binary.u32be(head, i + 4)
          next if size.nil? || size <= 16 || size > MAX_TEXT_BYTES

          value = head.byteslice(i + 20, size - 16).to_s
                      .force_encoding(Encoding::UTF_8).scrub("?").strip
          fields[label] = value unless value.empty? || fields.key?(label)
        end
      end

      # --- AIFF ----------------------------------------------------------

      def aiff(path)
        fields = {}
        SafeFile.open(path) do |io|
          form = io.read(12)
          return {} unless form&.bytesize == 12 && form.start_with?("FORM") &&
                           %w[AIFF AIFC].include?(form.byteslice(8, 4))

          fields["Codec"] = form.byteslice(8, 4) == "AIFC" ? "AIFF-C" : "AIFF (uncompressed)"
          while (chunk = io.read(8)) && chunk.bytesize == 8
            chunk_id = chunk.byteslice(0, 4)
            chunk_size = Binary.u32be(chunk, 4)
            break if chunk_size.nil?

            if chunk_id == "COMM"
              comm = io.read([chunk_size, 18].min).to_s
              io.seek(chunk_size - comm.bytesize, IO::SEEK_CUR) if chunk_size > comm.bytesize
              channels, frames, bits = comm.unpack("s>Ns>")
              rate = extended80_to_f(comm.byteslice(8, 10))
              fields["Channels"] = channels
              fields["Bit depth"] = "#{bits}-bit" if bits
              if rate.positive?
                fields["Sample rate"] = "#{rate.round} Hz"
                fields["Duration"] = Binary.duration_label(frames / rate) if frames&.positive?
              end
            else
              io.seek(chunk_size, IO::SEEK_CUR)
            end
            io.seek(1, IO::SEEK_CUR) if chunk_size.odd?
          end
        end
        fields
      end

      # AIFF sample rates are stored as 80-bit IEEE 754 extended floats.
      def extended80_to_f(bytes)
        return 0.0 if bytes.nil? || bytes.bytesize < 10

        sign_exponent = bytes.unpack1("n")
        exponent = sign_exponent & 0x7FFF
        mantissa = bytes.byteslice(2, 8).unpack1("Q>")
        return 0.0 if exponent.zero? && mantissa.zero?

        sign = sign_exponent.anybits?(0x8000) ? -1 : 1
        sign * mantissa.to_f * (2.0**(exponent - 16_383 - 63))
      end
    end
  end
end
