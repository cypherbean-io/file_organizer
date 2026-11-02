# frozen_string_literal: true

# Runs the whole suite: ruby tests/all.rb
Dir[File.expand_path("test_*.rb", __dir__)].sort.each { |file| require file }
