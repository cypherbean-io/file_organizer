# frozen_string_literal: true

require_relative "helper"
require_relative "../lib/file_organizer/gui"

# Pointing the browser at the GUI must not put the session key where other
# users can read it.
class TestGuiLaunch < Minitest::Test
  include OrganizerTest

  URL = "http://127.0.0.1:4321/?t=secret-key_123"

  def test_the_browser_is_handed_a_private_page_not_the_address
    handed = nil
    session = Gui::Session.new(@dir)
    launch_dir = Viewer.stub(:open_in_browser, ->(page) { handed = page; true }) do
      answering { Gui.announce(session, URL, true) }
    end

    refute_includes handed, "secret-key", "a command line is readable by every user"
    assert_equal ".html", File.extname(handed)
    assert_includes File.read(handed), URL
    assert_equal 0o600, File.stat(handed).mode & 0o777
    assert_equal 0o700, File.stat(launch_dir).mode & 0o777
    assert_equal launch_dir, File.dirname(handed)
    assert_includes output, "Opening your browser"
  ensure
    FileUtils.remove_entry(launch_dir) if launch_dir && File.directory?(launch_dir)
  end

  def test_no_page_is_written_when_no_browser_is_wanted
    session = Gui::Session.new(@dir)
    assert_nil answering { Gui.announce(session, URL, false) }
    assert_includes output, URL
  end

  def test_the_page_escapes_what_it_embeds
    dir, page = Gui.write_launch_page(%(http://127.0.0.1:1/?t=a"&<b>))
    html = File.read(page)

    refute_includes html, %(a"&<b>)
    assert_includes html, "a&quot;&amp;&lt;b&gt;"
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  def test_only_html_pages_are_handed_to_the_browser
    refute Viewer.open_in_browser(URL)
  end
end
