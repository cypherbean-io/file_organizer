# frozen_string_literal: true

# Generates small, valid test files for exercising file_organizer.
require "fileutils"

dir = File.expand_path("fixtures", __dir__)
FileUtils.rm_rf(dir)
FileUtils.mkdir_p(dir)

write = ->(name, data) { File.binwrite(File.join(dir, name), data) }

# --- text ---
write.call("notes.txt", "hello world\nline two\ttabbed\n" * 3)
write.call("evil\e[31mname.txt", "terminal escape in filename test\n")
write.call("script.sh", "#!/bin/sh\necho hi\n")
File.chmod(0o755, File.join(dir, "script.sh"))

# --- PNG 3x2 RGB ---
require "zlib"
def png_chunk(type, data)
  [data.bytesize].pack("N") + type + data + [Zlib.crc32(type + data)].pack("N")
end
ihdr = [3, 2, 8, 2, 0, 0, 0].pack("NNC5")
raw = ([0] + [255, 0, 0] * 3).pack("C*") + ([0] + [0, 255, 0] * 3).pack("C*")
png = "\x89PNG\r\n\x1A\n".b + png_chunk("IHDR", ihdr) +
      png_chunk("IDAT", Zlib::Deflate.deflate(raw)) + png_chunk("IEND", "")
write.call("tiny.png", png)

# --- PNG disguised as .mp3 (extension mismatch test) ---
write.call("sneaky.mp3", png)

# --- GIF 4x3 ---
gif = "GIF89a".b + [4, 3].pack("vv") + "\x00\x00\x00".b + "\x3B".b
write.call("tiny.gif", gif)

# --- BMP 5x4 ---
bmp_header = "BM".b + [70, 0, 26 + 4].pack("VVV") # size, reserved, offset (rough)
dib = [12, 5, 4, 1, 24].pack("Vl<l<vv") # BITMAPINFOHEADER-ish; we only read 18..25
bmp = "BM".b + [100].pack("V") + [0].pack("V") + [54].pack("V") +
      [40, 5, 4, 1, 24, 0, 0, 0, 0, 0, 0].pack("Vl<l<vvVVl<l<VV")
write.call("tiny.bmp", bmp)

# --- JPEG with EXIF (Make, Model, Orientation, ExifIFD: ISO, GPS) ---
def ifd_entry(tag, type, count, value)
  [tag, type, count].pack("nnN") + value
end
# Build TIFF (big-endian MM)
make = "TestCam\x00"
model = "Model X\x00"
datetime = "2024:06:01 12:00:00\x00"
# layout: header(8) + ifd0
ifd0_count = 5
ifd0_start = 8
ifd0_size = 2 + ifd0_count * 12 + 4
data_start = ifd0_start + ifd0_size
make_off = data_start
model_off = make_off + make.bytesize
dt_off = model_off + model.bytesize
exif_ifd_off = dt_off + datetime.bytesize
# exif ifd: 2 entries (ISO short, exposure rational)
exif_count = 2
exif_size = 2 + exif_count * 12 + 4
exp_off = exif_ifd_off + exif_size
gps_ifd_off = exp_off + 8
gps_count = 4
gps_size = 2 + gps_count * 12 + 4
lat_off = gps_ifd_off + gps_size
lon_off = lat_off + 24

tiff = "MM".b + [42].pack("n") + [ifd0_start].pack("N")
tiff += [ifd0_count].pack("n")
tiff += ifd_entry(0x010F, 2, make.bytesize, [make_off].pack("N"))
tiff += ifd_entry(0x0110, 2, model.bytesize, [model_off].pack("N"))
tiff += ifd_entry(0x0112, 3, 1, [6, 0].pack("nn"))
tiff += ifd_entry(0x8769, 4, 1, [exif_ifd_off].pack("N"))
tiff += ifd_entry(0x8825, 4, 1, [gps_ifd_off].pack("N"))
tiff += [0].pack("N") # next IFD
tiff += make + model + datetime
# exif ifd
tiff += [exif_count].pack("n")
tiff += ifd_entry(0x8827, 3, 1, [200, 0].pack("nn"))
tiff += ifd_entry(0x829A, 5, 1, [exp_off].pack("N"))
tiff += [0].pack("N")
tiff += [1, 250].pack("NN") # 1/250 s
# gps ifd
tiff += [gps_count].pack("n")
tiff += ifd_entry(0x0001, 2, 2, "N\x00\x00\x00")
tiff += ifd_entry(0x0002, 5, 3, [lat_off].pack("N"))
tiff += ifd_entry(0x0003, 2, 2, "W\x00\x00\x00")
tiff += ifd_entry(0x0004, 5, 3, [lon_off].pack("N"))
tiff += [0].pack("N")
tiff += [40, 1, 26, 1, 30, 1].pack("N6")   # 40° 26' 30" N
tiff += [79, 1, 58, 1, 56, 1].pack("N6")   # 79° 58' 56" W

exif_seg = "Exif\x00\x00".b + tiff
app1 = "\xFF\xE1".b + [exif_seg.bytesize + 2].pack("n") + exif_seg
sof0 = "\xFF\xC0".b + [17].pack("n") + [8, 20, 30, 3].pack("Cnnc") + "\x01\x22\x00\x02\x11\x01\x03\x11\x01".b
jpeg = "\xFF\xD8".b + app1 + sof0 + "\xFF\xDA".b + [2].pack("n") + "\xFF\xD9".b
write.call("photo.jpg", jpeg)

# --- WAV: 0.5 s of 440 Hz sine, 8000 Hz mono 16-bit ---
rate = 8000
samples = (0...(rate / 2)).map { |i| (Math.sin(2 * Math::PI * 440 * i / rate) * 12_000).round }
pcm = samples.pack("s<*")
fmt = [1, 1, rate, rate * 2, 2, 16].pack("vvVVvv")
wav = "RIFF".b + [4 + 8 + fmt.bytesize + 8 + pcm.bytesize].pack("V") + "WAVE".b +
      "fmt ".b + [fmt.bytesize].pack("V") + fmt +
      "data".b + [pcm.bytesize].pack("V") + pcm
write.call("tone.wav", wav)

# --- MP3: ID3v2.3 tag + a few CBR frames ---
def id3_frame(id, text)
  body = "\x00".b + text.encode(Encoding::ISO_8859_1).b
  id.b + [body.bytesize].pack("N") + "\x00\x00".b + body
end
frames = id3_frame("TIT2", "Test Song") + id3_frame("TPE1", "Test Artist") +
         id3_frame("TALB", "Test Album") + id3_frame("TYER", "2024")
tag_size = frames.bytesize
ss = [(tag_size >> 21) & 0x7F, (tag_size >> 14) & 0x7F, (tag_size >> 7) & 0x7F, tag_size & 0x7F].pack("C4")
id3 = "ID3".b + "\x03\x00\x00".b + ss + frames
# MPEG-1 Layer III, 128 kbps, 44100 Hz, stereo: FF FB 90 00; frame len = 417
frame_len = (144 * 128_000 / 44_100)
mp3_frame = "\xFF\xFB\x90\x00".b + ("\x00".b * (frame_len - 4))
write.call("song.mp3", id3 + mp3_frame * 40)

# --- FLAC: STREAMINFO + VORBIS_COMMENT ---
sample_rate = 44_100
total_samples = 44_100 * 3
packed = (sample_rate << 44) | ((2 - 1) << 41) | ((16 - 1) << 36) | total_samples
streaminfo = [1152, 1152].pack("nn") + "\x00\x00\x00".b * 2 + [packed].pack("Q>") + ("\x00".b * 16)
si_block = "\x00".b + [streaminfo.bytesize].pack("N")[1, 3] + streaminfo
vendor = "test"
comments = ["TITLE=Flac Song", "ARTIST=Flac Artist", "DATE=2023"]
vc = [vendor.bytesize].pack("V") + vendor + [comments.size].pack("V") +
     comments.map { |c| [c.bytesize].pack("V") + c }.join
vc_block = "\x84".b + [vc.bytesize].pack("N")[1, 3] + vc # last-block flag set
write.call("song.flac", "fLaC".b + si_block + vc_block)

# --- fake "photo" that is actually a Mach-O-style executable header ---
write.call("malware.jpg", "\xCF\xFA\xED\xFE".b + "\x00".b * 60)

# --- symlink ---
File.symlink(File.join(dir, "notes.txt"), File.join(dir, "link-to-notes"))

puts "fixtures written to #{dir}"
