# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "tmpdir"
require "fileutils"

require_relative "../lib/file_organizer"

# Shared scaffolding: a scratch directory per test, a way to answer the
# interactive prompts without a terminal, and a count of the file opens a
# code path performs.
module OrganizerTest
  include FileOrganizer

  module OpenCounter
    class << self
      attr_accessor :count
    end

    def open(*args, **options, &block)
      OpenCounter.count += 1 if OpenCounter.count
      super
    end
  end
  File.singleton_class.prepend(OpenCounter)

  attr_reader :output

  def setup
    @dir = Dir.mktmpdir("file_organizer_test")
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
  end

  def path(*parts)
    File.join(@dir, *parts)
  end

  def write(name, content = "hello\n")
    file = path(name)
    FileUtils.mkdir_p(File.dirname(file))
    File.binwrite(file, content)
    file
  end

  def mkdir(name)
    path(name).tap { |dir| FileUtils.mkdir_p(dir) }
  end

  # Runs the block with +lines+ queued on stdin. Returns the block's value;
  # everything printed is available afterwards from +output+.
  def answering(*lines)
    original_in = $stdin
    original_out = $stdout
    $stdin = StringIO.new(lines.map { |line| "#{line}\n" }.join)
    $stdout = StringIO.new
    begin
      result = yield
      @output = $stdout.string
      result
    ensure
      $stdin = original_in
      $stdout = original_out
    end
  end

  def count_file_opens
    OrganizerTest::OpenCounter.count = 0
    yield
    OrganizerTest::OpenCounter.count
  ensure
    OrganizerTest::OpenCounter.count = nil
  end
end
