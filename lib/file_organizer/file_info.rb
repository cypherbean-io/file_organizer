# frozen_string_literal: true

require "etc"

module FileOrganizer
  # Collects everything the program knows about a single file: filesystem
  # metadata (via lstat, so symlinks are inspected rather than followed) and
  # the content-based type detection.
  class FileInfo
    TIME_FORMAT = "%Y-%m-%d %H:%M:%S"

    attr_reader :path, :name, :detection

    def initialize(path)
      @path = path
      @name = File.basename(path)
      @stat = File.lstat(path)
      @detection = regular? ? TypeDetector.detect(path) : nil
    end

    def regular?
      @stat.file?
    end

    def symlink?
      @stat.symlink?
    end

    def size
      @stat.size
    end

    def hidden?
      name.start_with?(".")
    end

    def executable_bit?
      regular? && (@stat.mode & 0o111) != 0
    end

    def category
      detection&.category
    end

    def rows
      rows = [
        ["Name", Console.safe(name)],
        ["Location", Console.safe(File.dirname(File.expand_path(path)))],
        ["Type", type_description]
      ]
      rows.concat(extension_rows) if regular?
      rows << ["Size", human_size]
      rows << ["Permissions", "#{permission_string} (#{format('%03o', @stat.mode & 0o7777)})"]
      rows << ["Owner", "#{owner_name}:#{group_name}"]
      rows << ["Created", created_time]
      rows << ["Modified", @stat.mtime.strftime(TIME_FORMAT)]
      rows << ["Accessed", @stat.atime.strftime(TIME_FORMAT)]
      rows << ["Hidden", "yes (dotfile)"] if hidden?
      rows << ["Executable", "yes — 'open' is disabled for safety"] if executable_bit?
      rows
    end

    private

    def type_description
      if symlink?
        status = File.exist?(path) ? "target exists" : "BROKEN — target missing"
        "Symbolic link → #{Console.safe(link_target)} (#{status})"
      elsif regular?
        detection.description
      else
        @stat.ftype
      end
    end

    def extension_rows
      ext = File.extname(name)
      rows = [["Extension", ext.empty? ? "(none)" : Console.safe(ext.downcase)]]
      if TypeDetector.extension_mismatch?(path, detection)
        rows << ["Warning", "extension does not match detected content"]
      end
      rows
    end

    def link_target
      File.readlink(path)
    rescue SystemCallError
      "(unreadable)"
    end

    def human_size
      return "#{grouped(size)} bytes" if size < 1024

      value = size.to_f
      unit = "B"
      %w[KB MB GB TB PB].each do |u|
        break if value < 1024

        value /= 1024
        unit = u
      end
      format("%.1f %s (%s bytes)", value, unit, grouped(size))
    end

    def grouped(number)
      number.to_s.gsub(/(\d)(?=(\d{3})+\z)/, '\1,')
    end

    def permission_string
      type_char = { "file" => "-", "directory" => "d", "link" => "l" }.fetch(@stat.ftype, "?")
      bits = %w[r w x r w x r w x]
      perm = bits.each_with_index.map do |char, i|
        ((@stat.mode >> (8 - i)) & 1) == 1 ? char : "-"
      end
      type_char + perm.join
    end

    def owner_name
      Etc.getpwuid(@stat.uid)&.name || @stat.uid.to_s
    rescue ArgumentError
      @stat.uid.to_s
    end

    def group_name
      Etc.getgrgid(@stat.gid)&.name || @stat.gid.to_s
    rescue ArgumentError
      @stat.gid.to_s
    end

    def created_time
      @stat.birthtime.strftime(TIME_FORMAT)
    rescue NotImplementedError
      "#{@stat.ctime.strftime(TIME_FORMAT)} (inode change time; creation time unavailable)"
    end
  end
end
