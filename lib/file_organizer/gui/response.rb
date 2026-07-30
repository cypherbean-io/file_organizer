# frozen_string_literal: true

require "json"

module FileOrganizer
  module Gui
    # One HTTP response. A response either carries an in-memory body or names a
    # byte range of a file for the server to stream, which keeps whole media
    # files out of memory.
    class Response
      NO_STORE = "no-store"

      attr_reader :status, :headers, :body, :file_path, :file_offset, :file_length

      def initialize(status:, headers: {}, body: "", file_path: nil, file_offset: 0, file_length: 0)
        @status = status
        @headers = headers
        @body = body
        @file_path = file_path
        @file_offset = file_offset
        @file_length = file_length
      end

      def self.json(data, status: 200)
        new(status: status,
            headers: { "Content-Type" => "application/json; charset=utf-8", "Cache-Control" => NO_STORE },
            body: JSON.generate(data))
      end

      def self.text(message, status: 200)
        new(status: status,
            headers: { "Content-Type" => "text/plain; charset=utf-8", "Cache-Control" => NO_STORE },
            body: "#{message}\n")
      end

      def self.asset(body, content_type:, extra_headers: {})
        new(status: 200,
            headers: { "Content-Type" => content_type, "Cache-Control" => NO_STORE }.merge(extra_headers),
            body: body)
      end

      # Streams bytes of a file the user selected. The sandboxing headers make
      # sure that a media response can never do anything but decode as media,
      # even if it were opened as a top-level document.
      def self.file(path, content_type:, offset:, length:, total:)
        partial = length < total
        headers = {
          "Content-Type" => content_type,
          "Cache-Control" => NO_STORE,
          "Accept-Ranges" => "bytes",
          "Content-Security-Policy" => "default-src 'none'; sandbox"
        }
        headers["Content-Range"] = "bytes #{offset}-#{offset + length - 1}/#{total}" if partial
        new(status: partial ? 206 : 200, headers: headers,
            file_path: path, file_offset: offset, file_length: length)
      end

      def stream?
        !@file_path.nil?
      end

      def content_length
        stream? ? @file_length : @body.bytesize
      end
    end
  end
end
