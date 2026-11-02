# frozen_string_literal: true

require_relative "helper"

class TestConsole < Minitest::Test
  include OrganizerTest

  def test_escapes_terminal_escape_sequences
    assert_equal "evil\\x1B[31mname.txt", Console.safe("evil\e[31mname.txt")
  end

  def test_escapes_bidirectional_override_used_to_disguise_names
    # Rendered raw, this name reads as "invoice.png" in a terminal.
    assert_equal "invoice\\u{202E}gnp.exe", Console.safe("invoice‮gnp.exe")
  end

  def test_escapes_invisible_format_characters
    assert_equal "zero\\u{200B}width", Console.safe("zero​width")
    assert_equal "line\\u{2028}break", Console.safe("line break")
  end

  def test_leaves_ordinary_unicode_alone
    assert_equal "café — 中文.txt", Console.safe("café — 中文.txt")
  end

  def test_replaces_invalid_byte_sequences
    assert_equal "bad?name", Console.safe("bad\xFFname".b)
  end

  def test_strict_confirmation_accepts_only_the_whole_word
    assert answering("yes") { Console.confirm_exactly_yes?("Delete?") }
    refute answering("y") { Console.confirm_exactly_yes?("Delete?") }
    refute answering("YES") { Console.confirm_exactly_yes?("Delete?") }
    refute answering("") { Console.confirm_exactly_yes?("Delete?") }
  end

  def test_strict_confirmation_declines_at_end_of_input
    refute answering { Console.confirm_exactly_yes?("Delete?") }
  end

  def test_yes_no_confirmation_defaults_to_no
    assert answering("y") { Console.confirm?("Rename?") }
    assert answering("Yes") { Console.confirm?("Rename?") }
    refute answering("") { Console.confirm?("Rename?") }
    refute answering("maybe") { Console.confirm?("Rename?") }
    refute answering { Console.confirm?("Rename?") }
  end
end
