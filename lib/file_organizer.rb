# frozen_string_literal: true

module FileOrganizer
  class Error < StandardError; end
end

require_relative "file_organizer/version"
require_relative "file_organizer/safe_file"
require_relative "file_organizer/console"
require_relative "file_organizer/type_detector"
require_relative "file_organizer/file_info"
require_relative "file_organizer/directory"
require_relative "file_organizer/viewer"
require_relative "file_organizer/operations"
require_relative "file_organizer/actions"
require_relative "file_organizer/metadata/binary"
require_relative "file_organizer/metadata/exif_parser"
require_relative "file_organizer/metadata/photo"
require_relative "file_organizer/metadata/audio"
require_relative "file_organizer/cli"
