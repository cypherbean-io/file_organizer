# frozen_string_literal: true

require "json"
require "uri"

module FileOrganizer
  module Gui
    # One parsed HTTP request. Nothing here is trusted: the target, the headers
    # and the body are all arbitrary bytes that happened to arrive on a socket.
    class Request
      attr_reader :method, :target, :headers, :body

      def initialize(method:, target:, headers:, body:)
        @method = method
        @target = target
        @headers = headers
        @body = body
      end

      def get?
        @method == "GET"
      end

      def post?
        @method == "POST"
      end

      def path
        @path ||= @target.split("?", 2).first.to_s
      end

      def query
        @query ||= parse_query(@target.split("?", 2)[1])
      end

      def param(name)
        query[name]
      end

      # The JSON body of a POST, or an empty hash for anything unparseable.
      def json
        @json ||= begin
          data = JSON.parse(@body)
          data.is_a?(Hash) ? data : {}
        rescue JSON::ParserError, JSON::NestingError
          {}
        end
      end

      def string(key)
        value = json[key]
        value.is_a?(String) ? value : nil
      end

      def header(name)
        @headers[name]
      end

      def keep_alive?
        header("connection").to_s.downcase != "close"
      end

      private

      def parse_query(string)
        return {} if string.nil? || string.empty?

        URI.decode_www_form(string).to_h
      rescue ArgumentError
        {}
      end
    end
  end
end
