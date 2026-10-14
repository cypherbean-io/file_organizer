# frozen_string_literal: true

require_relative "helper"
require_relative "../lib/file_organizer/gui"

require "digest"
require "json"

# Drives Gui::App in-process: Request objects in, Response objects out. No
# socket is opened and no server thread is started.
module GuiAppTest
  include OrganizerTest

  TOKEN = "k" * 32
  HOST = "127.0.0.1:1234"
  ORIGIN = "http://127.0.0.1:1234"
  PNG = ("\x89PNG\r\n\x1A\n".b + "\x00\x00\x00\x0DIHDR".b + ("\x00".b * 48)).freeze

  attr_reader :app, :session

  def setup
    super
    build_app
  end

  def build_app(directory: @dir, read_only: false, dry_run: false, on_quit: nil)
    @session = Gui::Session.new(directory, read_only: read_only, dry_run: dry_run)
    @app = Gui::App.new(session: @session, token: TOKEN, hosts: [HOST, "localhost:1234"],
                        origin: ORIGIN, on_quit: on_quit)
  end

  # Header keys are lowercase, as Connection produces them. A nil value drops
  # the header altogether.
  def request(method, target, headers: {}, body: "")
    app.call(Gui::Request.new(method: method, target: target, headers: headers.compact, body: body))
  end

  def get(target, token: TOKEN, headers: {})
    base = { "host" => HOST, "x-session-token" => token }
    request("GET", target, headers: base.merge(headers))
  end

  # What the page's own fetch() sends for a write.
  def post(path, body = {}, token: TOKEN, headers: {})
    base = { "host" => HOST, "x-session-token" => token, "origin" => ORIGIN,
             "sec-fetch-site" => "same-origin", "content-type" => "application/json" }
    request("POST", path, headers: base.merge(headers), body: JSON.generate(body))
  end

  def json(response)
    JSON.parse(response.body)
  end

  def id(name)
    Gui.encode_id(name)
  end

  def listed_names
    json(get("/api/files"))["files"].map { |file| file["name"] }
  end

  # Replaces the system opener for the duration of the block, so no test ever
  # launches a real application. Yields the list of paths it was handed.
  def stub_opener(result = true)
    calls = []
    original = Viewer.method(:open_with_default_app)
    replace_opener do |file|
      calls << file
      result
    end
    yield calls
  ensure
    replace_opener(original) if original
  end

  # Removing the method first keeps `ruby -w` quiet about the redefinition.
  def replace_opener(implementation = nil, &block)
    Viewer.singleton_class.send(:remove_method, :open_with_default_app)
    Viewer.define_singleton_method(:open_with_default_app, implementation || block)
  end
end

class TestGuiAppAuthorization < Minitest::Test
  include GuiAppTest

  def test_interface_assets_are_served_without_the_session_key
    { "/assets/app.css" => "app.css", "/assets/app.js" => "app.js",
      "/assets/favicon.svg" => "favicon.svg" }.each do |route, file|
      response = get(route, token: nil)

      assert_equal 200, response.status, route
      assert_equal Gui::App::ASSETS[route][1], response.headers["Content-Type"]
      assert_equal File.binread(File.join(Gui::App::WEB_ROOT, file)), response.body
    end
  end

  def test_the_page_itself_needs_the_session_key
    assert_equal 403, get("/", token: nil).status

    page = get("/?t=#{TOKEN}", token: nil)
    assert_equal 200, page.status
    assert_equal "text/html; charset=utf-8", page.headers["Content-Type"]
    assert_equal Gui::App::CSP, page.headers["Content-Security-Policy"]
  end

  def test_every_api_read_needs_the_session_key
    write("notes.txt")
    file = id("notes.txt")
    ["/api/session", "/api/files", "/api/file?id=#{file}", "/api/text?id=#{file}",
     "/api/raw?id=#{file}", "/api/hash?id=#{file}", "/api/nope"].each do |target|
      response = get(target, token: nil)
      assert_equal 403, response.status, target
      assert_includes response.body, "Not authorized", target
    end
  end

  def test_every_api_write_needs_the_session_key
    notes = write("notes.txt", "keep me\n")
    destination = mkdir("dest")
    body = { "id" => id("notes.txt"), "name" => "renamed.txt", "destination" => destination,
             "confirm" => "yes", "path" => destination }

    stub_opener do |calls|
      (Gui::App::MUTATING_ROUTES + ["/api/folder", "/api/quit"]).each do |route|
        assert_equal 403, post(route, body, token: nil).status, route
      end
      assert_empty calls
    end
    assert_equal "keep me\n", File.read(notes)
    assert_empty Dir.children(destination)
    assert_equal @dir, session.directory
  end

  def test_the_key_is_accepted_from_the_header_or_the_query
    assert_equal 200, get("/api/session").status
    assert_equal 200, get("/api/session?t=#{TOKEN}", token: nil).status
  end

  def test_a_wrong_key_of_the_same_length_is_refused
    wrong = "#{'k' * 31}j"
    assert_equal TOKEN.bytesize, wrong.bytesize

    assert_equal 403, get("/api/session", token: wrong).status
    assert_equal 403, get("/api/session?t=#{wrong}", token: nil).status
    assert_equal 403, get("/?t=#{wrong}", token: nil).status
  end

  def test_a_wrong_key_of_a_different_length_is_refused
    ["", "k", "k" * 31, "k" * 33, "#{TOKEN}#{TOKEN}", "#{TOKEN} "].each do |wrong|
      assert_equal 403, get("/api/session", token: wrong).status, wrong.inspect
      assert_equal 403, get("/api/session?t=#{URI.encode_www_form_component(wrong)}", token: nil).status,
                   wrong.inspect
    end
  end

  def test_an_empty_query_key_is_refused
    assert_equal 403, get("/api/session?t=", token: nil).status
    assert_equal 403, get("/api/session?t", token: nil).status
  end
end

class TestGuiAppHostAndOrigin < Minitest::Test
  include GuiAppTest

  # DNS rebinding: a hostile page resolves its own name to 127.0.0.1, and the
  # browser then sends that name in Host. Even the assets are refused.
  def test_requests_naming_another_host_are_refused
    ["evil.example:1234", "evil.example", "127.0.0.1:9999", "127.0.0.1", "localhost", ""].each do |host|
      headers = { "host" => host }
      response = get("/api/session", headers: headers)
      assert_equal 403, response.status, host.inspect
      assert_includes response.body, "Unexpected Host header"
      assert_equal 403, get("/assets/app.js", token: nil, headers: headers).status, host.inspect
      assert_equal 403, post("/api/quit", {}, headers: headers).status, host.inspect
    end
  end

  def test_both_loopback_names_are_accepted_in_any_case
    ["127.0.0.1:1234", "localhost:1234", "LOCALHOST:1234", "LocalHost:1234"].each do |host|
      assert_equal 200, get("/api/session", headers: { "host" => host }).status, host
    end
  end

  # A browser always sends Host, so a request without one is not a rebinding
  # attempt — but it still gets nothing without the key.
  def test_a_request_without_a_host_header_still_needs_the_key
    no_host = { "host" => nil }

    assert_equal 403, get("/api/session", token: nil, headers: no_host).status
    assert_equal 403, get("/", token: nil, headers: no_host).status
    assert_equal 200, get("/api/session", headers: no_host).status
    assert_equal 200, get("/assets/app.css", token: nil, headers: no_host).status
  end

  def test_writes_from_a_foreign_origin_are_refused
    file = write("keep.txt")
    ["http://evil.example", "null", "http://127.0.0.1:9999", "https://127.0.0.1:1234",
     "http://127.0.0.1:1234/", ""].each do |origin|
      response = post("/api/delete", { "id" => id("keep.txt"), "confirm" => "yes" },
                      headers: { "origin" => origin })
      assert_equal 403, response.status, origin.inspect
      assert_includes response.body, "Cross-origin"
    end
    assert_path_exists file
  end

  def test_writes_not_labelled_same_origin_are_refused
    file = write("keep.txt")
    ["cross-site", "same-site", "none", ""].each do |site|
      response = post("/api/delete", { "id" => id("keep.txt"), "confirm" => "yes" },
                      headers: { "sec-fetch-site" => site })
      assert_equal 403, response.status, site.inspect
    end
    assert_path_exists file
  end

  # The cross-site label wins even when the Origin header looks right.
  def test_a_cross_site_label_is_refused_with_our_own_origin
    file = write("keep.txt")
    response = post("/api/delete", { "id" => id("keep.txt"), "confirm" => "yes" },
                    headers: { "origin" => ORIGIN, "sec-fetch-site" => "cross-site" })

    assert_equal 403, response.status
    assert_path_exists file
  end

  # A client that is not a browser sends neither header; the key is then the
  # only credential, as for any read.
  def test_writes_without_browser_labels_are_accepted_with_the_key
    file = write("gone.txt")
    response = post("/api/delete", { "id" => id("gone.txt"), "confirm" => "yes" },
                    headers: { "origin" => nil, "sec-fetch-site" => nil })

    assert_equal "ok", json(response)["status"]
    refute_path_exists file
  end

  def test_reads_are_not_subject_to_the_origin_check
    response = get("/api/session", headers: { "origin" => "http://evil.example", "sec-fetch-site" => "cross-site" })
    assert_equal 200, response.status
  end
end

class TestGuiAppListing < Minitest::Test
  include GuiAppTest

  def test_lists_regular_files_and_symlinks_but_not_directories
    write("b.txt")
    write("A.txt")
    mkdir("sub")
    File.symlink(path("b.txt"), path("link"))

    data = json(get("/api/files"))
    assert_equal ["A.txt", "b.txt", "link"], data["files"].map { |file| file["name"] }
    assert_equal @dir, data["directory"]
    assert_equal false, data["truncated"]
    assert_equal Gui::Session::MAX_ENTRIES, data["limit"]

    link = data["files"].find { |file| file["name"] == "link" }
    assert_equal true, link["symlink"]
    assert_equal "link", link["category"]
    assert_equal false, link["openable"]
  end

  def test_ids_round_trip_to_the_same_file
    write("one.txt", "first\n")
    write("two words.txt", "second\n")
    write(".hidden", "third\n")

    files = json(get("/api/files"))["files"]
    assert_equal 3, files.size
    files.each do |summary|
      assert_match Gui::ID_PATTERN, summary["id"]
      assert_equal summary["name"], Gui.decode_id(summary["id"])

      detail = json(get("/api/file?id=#{summary['id']}"))
      assert_equal summary["name"], detail["name"]
      assert_equal summary["id"], detail["id"]
    end
  end

  # File names are untrusted bytes: escape sequences, bidi overrides and
  # invalid UTF-8 must reach the page defanged, while the id still names the
  # file exactly.
  def test_names_are_sanitized_and_their_ids_still_reach_the_file
    names = ["bell\a.txt", "esc\e[2J.txt", "rlo‮gnp.exe", "caf\xE9.txt".b]
    names.each { |name| File.binwrite(File.join(@dir.b, name.b), "content of #{name.b.inspect}") }

    response = get("/api/files")
    assert response.body.dup.force_encoding(Encoding::UTF_8).valid_encoding?
    files = json(response)["files"]
    assert_equal names.size, files.size

    files.each do |summary|
      refute_match(/[\p{Cc}\p{Cf}]/, summary["name"])
      raw = Gui.decode_id(summary["id"])
      assert_includes names.map(&:b), raw.b

      hash = json(get("/api/hash?id=#{summary['id']}"))
      assert_equal "ok", hash["status"]
      assert_equal Digest::SHA256.file(File.join(@dir.b, raw.b)).hexdigest, hash["sha256"]
    end
    listed = files.map { |summary| summary["name"] }
    assert_includes listed, "bell\\x07.txt"
    assert_includes listed, "esc\\x1B[2J.txt"
    assert_includes listed, "rlo\\u{202E}gnp.exe"
    assert_includes listed, "caf?.txt"
  end

  def test_summaries_flag_content_that_disagrees_with_the_extension
    write("photo.pdf", PNG)
    summary = json(get("/api/files"))["files"].first

    assert_equal "png", summary["format"]
    assert_equal true, summary["mismatch"]
    assert_equal "image", summary["media"]
  end

  def test_text_preview_is_served_for_text_only
    write("notes.txt", "line one\nline \e[31mtwo\n")
    write("pic.png", PNG)

    text = json(get("/api/text?id=#{id('notes.txt')}"))
    assert_equal "ok", text["status"]
    assert_equal ["line one", "line \\x1B[31mtwo"], text["lines"]
    assert_equal "error", json(get("/api/text?id=#{id('pic.png')}"))["status"]
  end
end

class TestGuiAppFileIds < Minitest::Test
  include GuiAppTest

  def setup
    super
    @secret = write("secret.txt", "outside the reviewed folder\n")
    @root = mkdir("root")
    write("root/a/b", "nested\n")
    write("root/visible.txt")
    mkdir("root/sub")
    build_app(directory: @root)
  end

  READ_ROUTES = %w[/api/file /api/text /api/raw /api/hash].freeze

  # An id is decoded to a name and joined onto the reviewed folder; a decoded
  # name that is not a single path component must never reach the disk.
  def test_ids_that_decode_to_traversal_are_not_found
    ["../secret.txt", "a/b", ".", "..", "nul\0byte", "visible.txt\0", @secret, "/etc/passwd",
     "./visible.txt", "x" * 256].each do |name|
      READ_ROUTES.each do |route|
        response = get("#{route}?id=#{id(name)}")
        assert_equal 404, response.status, "#{route} #{name.inspect}"
      end
    end
  end

  def test_traversal_ids_cannot_reach_a_write
    stub_opener do |calls|
      %w[/api/delete /api/rename /api/open /api/copy /api/move].each do |route|
        response = post(route, { "id" => id("../secret.txt"), "confirm" => "yes", "name" => "stolen.txt",
                                 "destination" => @root })
        assert_equal 404, response.status, route
      end
      assert_empty calls
    end
    assert_equal "outside the reviewed folder\n", File.read(@secret)
    refute_path_exists path("root", "secret.txt")
  end

  def test_ids_that_are_not_ids_are_not_found
    ["../secret.txt", "%2e%2e", "", "a%20b", "a.b", "Zm9v=", "A" * 701].each do |raw|
      assert_equal 404, get("/api/file?id=#{raw}").status, raw
    end
    assert_equal 404, get("/api/file").status
    assert_equal 404, post("/api/delete", { "id" => 42, "confirm" => "yes" }).status
  end

  def test_a_subdirectory_is_not_a_file
    assert_equal 404, get("/api/file?id=#{id('sub')}").status
    assert_equal 404, post("/api/delete", { "id" => id("sub"), "confirm" => "yes" }).status
    assert File.directory?(path("root", "sub"))
  end

  def test_an_ordinary_id_still_resolves
    assert_equal 200, get("/api/file?id=#{id('visible.txt')}").status
  end
end

class TestGuiAppWrites < Minitest::Test
  include GuiAppTest

  # The page asks for the typed word, but the server must not trust that it
  # did: anything other than the exact string "yes" deletes nothing.
  def test_delete_requires_the_word_yes
    file = write("keep.txt")
    [nil, "y", "Yes", "YES", " yes", "yes ", true, 1, ["yes"]].each do |answer|
      body = { "id" => id("keep.txt") }
      body["confirm"] = answer unless answer.nil?
      result = json(post("/api/delete", body))

      assert_equal "error", result["status"], answer.inspect
      assert_includes result["message"], "'yes'"
      assert_path_exists file
    end

    result = json(post("/api/delete", { "id" => id("keep.txt"), "confirm" => "yes" }))
    assert_equal "ok", result["status"]
    assert_nil result["id"]
    refute_path_exists file
  end

  def test_delete_removes_a_symlink_and_not_its_target
    target = write("target.txt", "still here\n")
    File.symlink(target, path("link"))

    assert_equal "ok", json(post("/api/delete", { "id" => id("link"), "confirm" => "yes" }))["status"]
    refute File.symlink?(path("link"))
    assert_equal "still here\n", File.read(target)
  end

  def test_rename_answers_with_the_id_of_the_new_name
    write("before.txt", "payload\n")
    result = json(post("/api/rename", { "id" => id("before.txt"), "name" => "after.txt" }))

    assert_equal "ok", result["status"]
    assert_equal id("after.txt"), result["id"]
    assert_equal "after.txt", json(get("/api/file?id=#{result['id']}"))["name"]
    refute_path_exists path("before.txt")
  end

  def test_rename_refuses_names_that_leave_the_folder
    file = write("before.txt")
    ["../escaped.txt", "sub/nested.txt", "..", ".", "bell\a.txt"].each do |name|
      result = json(post("/api/rename", { "id" => id("before.txt"), "name" => name }))
      assert_equal "error", result["status"], name.inspect
      assert_equal id("before.txt"), result["id"]
    end
    assert_equal "error", json(post("/api/rename", { "id" => id("before.txt"), "name" => "" }))["status"]
    assert_equal "error", json(post("/api/rename", { "id" => id("before.txt"), "name" => 7 }))["status"]

    assert_path_exists file
    assert_equal ["before.txt"], Dir.children(@dir)
    refute_path_exists File.join(File.dirname(@dir), "escaped.txt")
  end

  def test_rename_refuses_to_replace_an_existing_file
    write("before.txt")
    write("taken.txt", "do not lose me\n")
    result = json(post("/api/rename", { "id" => id("before.txt"), "name" => "taken.txt" }))

    assert_equal "conflict", result["status"]
    assert_equal "do not lose me\n", File.read(path("taken.txt"))
  end

  def test_copy_overwrites_only_when_asked_with_a_real_true
    write("report.txt", "new\n")
    destination = mkdir("dest")
    existing = File.join(destination, "report.txt")
    File.binwrite(existing, "old\n")
    body = { "id" => id("report.txt"), "destination" => destination }

    [nil, "true", 1, "yes"].each do |overwrite|
      result = json(post("/api/copy", overwrite.nil? ? body : body.merge("overwrite" => overwrite)))
      assert_equal "conflict", result["status"], overwrite.inspect
      assert_equal "old\n", File.read(existing)
    end

    result = json(post("/api/copy", body.merge("overwrite" => true)))
    assert_equal "ok", result["status"]
    assert_equal id("report.txt"), result["id"]
    assert_equal "new\n", File.read(existing)
    assert_path_exists path("report.txt")
  end

  def test_copy_refuses_to_write_through_a_symlink_at_the_destination
    write("report.txt", "payload\n")
    outside = write("outside/precious.txt", "must survive\n")
    destination = mkdir("dest")
    File.symlink(outside, File.join(destination, "report.txt"))

    result = json(post("/api/copy", { "id" => id("report.txt"), "destination" => destination, "overwrite" => true }))
    assert_equal "error", result["status"]
    assert_includes result["message"], "symbolic link"
    assert_equal "must survive\n", File.read(outside)
  end

  def test_move_answers_without_an_id
    write("report.txt", "payload\n")
    destination = mkdir("dest")
    result = json(post("/api/move", { "id" => id("report.txt"), "destination" => destination }))

    assert_equal "ok", result["status"]
    assert_nil result["id"]
    refute_path_exists path("report.txt")
    assert_equal "payload\n", File.read(File.join(destination, "report.txt"))
  end

  def test_a_transfer_needs_a_destination
    write("report.txt")
    %w[/api/copy /api/move].each do |route|
      result = json(post(route, { "id" => id("report.txt") }))
      assert_equal "error", result["status"]
      assert_includes result["message"], "destination"
    end
    assert_path_exists path("report.txt")
  end

  def test_writes_cannot_be_reached_with_a_get
    file = write("keep.txt")
    %w[/api/delete /api/rename /api/move /api/open].each do |route|
      assert_equal 404, get("#{route}?id=#{id('keep.txt')}&confirm=yes&name=x.txt").status, route
    end
    assert_path_exists file
  end

  def test_an_unknown_post_route_is_not_found
    assert_equal 404, post("/api/files").status
    assert_equal 404, post("/api/rename/", { "id" => id("x") }).status
  end
end

class TestGuiAppReadOnly < Minitest::Test
  include GuiAppTest

  def setup
    super
    build_app(read_only: true)
    @notes = write("notes.txt", "keep me\n")
    @destination = mkdir("dest")
  end

  def test_refuses_every_mutating_route_and_leaves_the_files_alone
    file = id("notes.txt")
    bodies = {
      "/api/rename" => { "id" => file, "name" => "renamed.txt" },
      "/api/copy" => { "id" => file, "destination" => @destination, "overwrite" => true },
      "/api/move" => { "id" => file, "destination" => @destination, "overwrite" => true },
      "/api/delete" => { "id" => file, "confirm" => "yes" },
      "/api/open" => { "id" => file, "confirm" => "yes" }
    }
    assert_equal Gui::App::MUTATING_ROUTES.sort, bodies.keys.sort

    stub_opener do |calls|
      bodies.each do |route, body|
        response = post(route, body)
        assert_equal 403, response.status, route
        assert_equal "error", json(response)["status"]
        assert_includes json(response)["message"], "Read-only"
      end
      assert_empty calls
    end

    assert_equal "keep me\n", File.read(@notes)
    assert_equal %w[dest notes.txt], Dir.children(@dir).sort
    assert_empty Dir.children(@destination)
  end

  # The refusal does not depend on the id naming a real file.
  def test_refuses_mutating_routes_before_looking_up_the_file
    Gui::App::MUTATING_ROUTES.each do |route|
      assert_equal 403, post(route, { "id" => id("no-such-file") }).status, route
    end
  end

  def test_still_serves_reads_including_checksums
    hash = json(get("/api/hash?id=#{id('notes.txt')}"))
    assert_equal "ok", hash["status"]
    assert_equal Digest::SHA256.hexdigest("keep me\n"), hash["sha256"]

    assert_equal ["dest"], json(get("/api/session"))["subdirectories"].map { |entry| entry["name"] }
    assert_equal ["notes.txt"], listed_names
    assert_equal 200, get("/api/file?id=#{id('notes.txt')}").status
    assert_equal "ok", json(get("/api/text?id=#{id('notes.txt')}"))["status"]
  end

  # Nothing can be changed in read-only mode, so a system folder can be
  # browsed without the confirmation a writable session asks for.
  def test_a_system_folder_needs_no_confirmation
    result = json(post("/api/folder", { "path" => "/etc" }))

    assert_equal "ok", result["status"]
    assert_equal "/etc", session.directory
  end

  def test_read_only_wins_over_dry_run
    build_app(read_only: true, dry_run: true)
    data = json(get("/api/session"))

    assert_equal true, data["readOnly"]
    assert_equal false, data["dryRun"]
    assert_equal 403, post("/api/delete", { "id" => id("notes.txt"), "confirm" => "yes" }).status
    assert_path_exists @notes
  end
end

class TestGuiAppDryRun < Minitest::Test
  include GuiAppTest

  def setup
    super
    build_app(dry_run: true)
    @source = write("report.txt", "payload\n")
    @destination = mkdir("dest")
  end

  def test_rename_is_reported_and_not_done
    result = json(post("/api/rename", { "id" => id("report.txt"), "name" => "after.txt" }))

    assert_equal "ok", result["status"]
    assert_includes result["message"], "[dry run] would rename"
    assert_equal id("report.txt"), result["id"]
    assert_path_exists @source
    refute_path_exists path("after.txt")
  end

  def test_copy_and_move_are_reported_and_not_done
    %w[copy move].each do |operation|
      result = json(post("/api/#{operation}", { "id" => id("report.txt"), "destination" => @destination }))

      assert_equal "ok", result["status"], operation
      assert_includes result["message"], "[dry run] would #{operation}"
      assert_equal id("report.txt"), result["id"]
    end
    assert_equal "payload\n", File.read(@source)
    assert_empty Dir.children(@destination)
  end

  def test_delete_is_reported_and_not_done
    result = json(post("/api/delete", { "id" => id("report.txt"), "confirm" => "yes" }))

    assert_equal "ok", result["status"]
    assert_includes result["message"], "[dry run] would delete"
    assert_path_exists @source
  end

  def test_open_is_reported_and_no_application_is_started
    stub_opener do |calls|
      result = json(post("/api/open", { "id" => id("report.txt") }))
      assert_equal "ok", result["status"]
      assert_includes result["message"], "[dry run]"
      assert_empty calls
    end
  end

  def test_requests_are_still_validated
    assert_equal "error", json(post("/api/rename", { "id" => id("report.txt"), "name" => "../x" }))["status"]
    assert_equal "error", json(post("/api/delete", { "id" => id("report.txt") }))["status"]
    assert_equal "error", json(post("/api/copy", { "id" => id("report.txt"), "destination" => path("missing") }))["status"]
    assert_path_exists @source
  end

  def test_the_session_reports_dry_run
    data = json(get("/api/session"))
    assert_equal true, data["dryRun"]
    assert_equal false, data["readOnly"]
  end
end

class TestGuiAppOpen < Minitest::Test
  include GuiAppTest

  def open_file(name, body = {})
    json(post("/api/open", { "id" => id(name) }.merge(body)))
  end

  def test_hands_a_plain_document_to_the_system_opener
    file = write("notes.txt")
    stub_opener do |calls|
      assert_equal "ok", open_file("notes.txt")["status"]
      assert_equal [file], calls
    end
  end

  def test_reports_when_no_opener_is_available
    write("notes.txt")
    stub_opener(false) do |calls|
      result = open_file("notes.txt")
      assert_equal "error", result["status"]
      assert_includes result["message"], "Could not open"
      assert_equal 1, calls.size
    end
  end

  # A .desktop entry is inert text that tells the desktop to run a command
  # line; the extension decides, whatever the content looks like, and no
  # confirmation unlocks it.
  def test_launcher_files_are_never_opened
    write("app.desktop", "[Desktop Entry]\nType=Application\nExec=sh -c 'echo pwned'\n")
    write("Shortcut.DESKTOP", "[Desktop Entry]\nExec=true\n")
    write("link.lnk", "plain text\n")

    stub_opener do |calls|
      %w[app.desktop Shortcut.DESKTOP link.lnk].each do |name|
        result = open_file(name, "confirm" => "yes")
        assert_equal "error", result["status"], name
        assert_includes result["message"], "launcher"
      end
      assert_empty calls
    end
  end

  def test_executables_and_symlinks_are_never_opened
    write("tool", "\x7FELF\x02\x01\x01\x00padding".b)
    File.chmod(0o755, write("run.txt", "hello\n"))
    File.symlink(write("target.txt"), path("link.txt"))

    stub_opener do |calls|
      %w[tool run.txt link.txt].each do |name|
        assert_equal "error", open_file(name, "confirm" => "yes")["status"], name
      end
      assert_empty calls
    end
  end

  # The opener picks the application from the extension, so PNG bytes named
  # .pdf would go to the PDF reader. Nothing is launched until the request
  # confirms it in as many words.
  def test_a_disguised_file_needs_confirmation_before_opening
    file = write("invoice.pdf", PNG)

    stub_opener do |calls|
      [{}, { "confirm" => "y" }, { "confirm" => true }, { "confirm" => "YES" }].each do |body|
        result = open_file("invoice.pdf", body)
        assert_equal "confirm", result["status"], body.inspect
        assert_includes result["message"], "extension"
      end
      assert_empty calls

      assert_equal "ok", open_file("invoice.pdf", "confirm" => "yes")["status"]
      assert_equal [file], calls
    end
  end
end

class TestGuiAppFolder < Minitest::Test
  include GuiAppTest

  def change(path, body = {})
    json(post("/api/folder", { "path" => path }.merge(body)))
  end

  def test_changes_to_an_ordinary_folder
    sub = mkdir("sub")
    File.binwrite(File.join(sub, "inside.txt"), "x")

    result = change(sub)
    assert_equal "ok", result["status"]
    assert_equal sub, session.directory
    assert_equal ["inside.txt"], listed_names
  end

  def test_a_system_or_home_folder_needs_confirmation
    ["/etc", "/etc/", "/usr/../etc", "/usr/share", "/", "~"].each do |guarded|
      result = change(guarded)
      assert_equal "confirm", result["status"], guarded
      assert_equal @dir, session.directory, guarded

      assert_equal "confirm", change(guarded, "confirm" => "y")["status"], guarded
      assert_equal @dir, session.directory
    end
  end

  def test_a_system_folder_is_entered_once_confirmed
    result = change("/etc", "confirm" => "yes")

    assert_equal "ok", result["status"]
    assert_equal "/etc", session.directory
  end

  def test_unusable_folders_are_reported_and_nothing_changes
    file = write("plain.txt")
    { path("missing") => "Does not exist", file => "Not a directory", "" => "A folder is required" }.each do |target, message|
      result = change(target)
      assert_equal "error", result["status"], target
      assert_includes result["message"], message
    end
    assert_equal "error", change("bad\0path")["status"]
    assert_equal "error", json(post("/api/folder", { "path" => ["/tmp"] }))["status"]
    assert_equal @dir, session.directory
  end
end

class TestGuiAppRaw < Minitest::Test
  include GuiAppTest

  def raw(name, range: nil)
    get("/api/raw?id=#{id(name)}", headers: { "range" => range })
  end

  def test_serves_a_png_sandboxed_and_unsniffable
    file = write("pic.png", PNG)
    response = raw("pic.png")

    assert_equal 200, response.status
    assert response.stream?
    assert_equal file, response.file_path
    assert_equal 0, response.file_offset
    assert_equal PNG.bytesize, response.file_length
    assert_equal "image/png", response.headers["Content-Type"]
    assert_equal "default-src 'none'; sandbox", response.headers["Content-Security-Policy"]
    assert_equal "bytes", response.headers["Accept-Ranges"]
    assert_nil response.headers["Content-Range"]

    # nosniff is added to every response on its way out; check it is there.
    head = Gui::Server.new.send(:head, response)
    assert_includes head, "X-Content-Type-Options: nosniff\r\n"
    assert_includes head, "Content-Security-Policy: default-src 'none'; sandbox\r\n"
    assert_includes head, "Content-Length: #{PNG.bytesize}\r\n"
  end

  def test_serves_a_requested_byte_range
    write("pic.png", PNG)
    response = raw("pic.png", range: "bytes=8-15")

    assert_equal 206, response.status
    assert_equal 8, response.file_offset
    assert_equal 8, response.file_length
    assert_equal "bytes 8-15/#{PNG.bytesize}", response.headers["Content-Range"]
  end

  def test_a_range_past_the_end_is_unsatisfiable
    write("pic.png", PNG)
    response = raw("pic.png", range: "bytes=#{PNG.bytesize}-")

    assert_equal 416, response.status
    refute response.stream?
    assert_equal "bytes */#{PNG.bytesize}", response.headers["Content-Range"]
  end

  def test_a_long_range_is_capped
    file = write("big.png", PNG)
    total = Gui::App::MAX_RANGE_BYTES + 4096
    File.truncate(file, total) # sparse: nothing is actually written
    response = raw("big.png", range: "bytes=0-")

    assert_equal 206, response.status
    assert_equal Gui::App::MAX_RANGE_BYTES, response.file_length
    assert_equal "bytes 0-#{Gui::App::MAX_RANGE_BYTES - 1}/#{total}", response.headers["Content-Range"]
  end

  # SVG and PDF are documents that can carry script; text and HTML are not
  # media. None of them is ever served to the page as a file — whatever the
  # extension says, since the type comes from the content.
  def test_scriptable_and_non_media_formats_are_refused
    write("drawing.svg", %(<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>))
    write("drawing.png", %(<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>))
    write("paper.pdf", "%PDF-1.7\n1 0 obj << /JS (app.alert(1)) >> endobj\n")
    write("notes.txt", "hello\n")
    write("page.html", "<html><script>alert(1)</script></html>")

    %w[drawing.svg drawing.png paper.pdf notes.txt page.html].each do |name|
      response = raw(name)
      assert_equal 415, response.status, name
      refute response.stream?, name
    end
  end

  def test_a_symlink_is_refused_even_to_a_png
    write("pic.png", PNG)
    outside = write("outside/elsewhere.png", PNG)
    File.symlink(path("pic.png"), path("link.png"))
    File.symlink(outside, path("away.png"))

    assert_equal 415, raw("link.png").status
    assert_equal 415, raw("away.png").status
  end

  def test_checksums_refuse_a_symlink
    File.symlink(write("target.txt"), path("link.txt"))
    assert_equal "error", json(get("/api/hash?id=#{id('link.txt')}"))["status"]
  end
end

class TestGuiAppByteRange < Minitest::Test
  include GuiAppTest

  MAX = Gui::App::MAX_RANGE_BYTES

  def range(header, total = 1000)
    app.send(:byte_range, header, total)
  end

  def test_no_header_or_junk_serves_the_whole_file
    [nil, "", "bytes=", "bytes=abc", "items=0-9", "Bytes 0-9", "bytes=0-9,20-29", "bytes=0-9x",
     "bytes=--5", "bytes=1-2-3", "bytes=1234567890123456-", "bytes=0-1234567890123456"].each do |header|
      assert_equal [0, 1000, true], range(header), header.inspect
    end
  end

  def test_explicit_ranges
    assert_equal [0, 100, true], range("bytes=0-99")
    assert_equal [0, 1, true], range("bytes=0-0")
    assert_equal [999, 1, true], range("bytes=999-999")
    assert_equal [10, 10, true], range("  bytes=10-19  ")
    assert_equal [0, 1000, true], range("bytes=0-999")
  end

  def test_a_last_position_past_the_end_is_clamped
    assert_equal [990, 10, true], range("bytes=990-5000")
    assert_equal [0, 1000, true], range("bytes=0-999999999999999")
  end

  def test_open_ended_ranges_run_to_the_end
    assert_equal [500, 500, true], range("bytes=500-")
    assert_equal [999, 1, true], range("bytes=999-")
    assert_equal [0, 1000, true], range("bytes=0-")
  end

  def test_suffix_ranges_count_from_the_end
    assert_equal [900, 100, true], range("bytes=-100")
    assert_equal [999, 1, true], range("bytes=-1")
    assert_equal [0, 1000, true], range("bytes=-1000")
    assert_equal [0, 1000, true], range("bytes=-5000")
  end

  def test_ranges_beyond_the_end_are_unsatisfiable
    ["bytes=1000-", "bytes=1000-1000", "bytes=5000-6000", "bytes=999999999999999-", "bytes=-0"].each do |header|
      refute range(header)[2], header
    end
  end

  def test_an_inverted_range_never_yields_a_negative_length
    offset, length, satisfiable = range("bytes=500-100")
    assert(!satisfiable || (offset.zero? && length == 1000))
  end

  def test_an_empty_file_is_served_whole_whatever_is_asked
    ["bytes=0-", "bytes=-1", "bytes=5-10", nil].each do |header|
      assert_equal [0, 0, true], range(header, 0), header.inspect
    end
  end

  def test_a_single_response_is_capped
    total = MAX * 4
    assert_equal [0, MAX, true], range("bytes=0-", total)
    assert_equal [0, MAX, true], range("bytes=0-#{MAX * 2}", total)
    assert_equal [MAX * 2, MAX, true], range("bytes=-#{MAX * 2}", total)
    assert_equal [MAX, 10, true], range("bytes=#{MAX}-#{MAX + 9}", total)
    # Without a Range header the whole file is streamed, as a 200.
    assert_equal [0, total, true], range(nil, total)
  end
end

class TestGuiAppSession < Minitest::Test
  include GuiAppTest

  def test_session_payload_describes_the_folder_and_its_flags
    mkdir("sub")
    mkdir("evil\e[2J")
    write("file.txt")
    data = json(get("/api/session"))

    assert_equal @dir, data["directory"]
    assert_equal File.dirname(@dir), data["parent"]
    assert_equal false, data["readOnly"]
    assert_equal false, data["dryRun"]
    assert_equal "general", data["mode"]
    assert_equal VERSION, data["version"]
    assert_equal "/", data["separator"]
    assert_equal [{ "name" => "evil\\x1B[2J", "path" => "#{@dir}/evil\\x1B[2J" },
                  { "name" => "sub", "path" => path("sub") }], data["subdirectories"]
  end

  def test_session_payload_reports_read_only
    build_app(read_only: true)
    data = json(get("/api/session"))
    assert_equal true, data["readOnly"]
    assert_equal false, data["dryRun"]
  end

  def test_the_root_folder_has_no_parent
    build_app(directory: "/")
    assert_nil json(get("/api/session"))["parent"]
  end

  def test_quit_answers_first_and_stops_a_moment_later
    stopped = Queue.new
    build_app(on_quit: -> { stopped << Thread.current })

    result = json(post("/api/quit"))
    assert_equal "ok", result["status"]

    thread = stopped.pop(timeout: 5)
    refute_nil thread, "on_quit was never called"
    thread.join(5)
  end

  # Whatever goes wrong inside a handler, the page gets a generic answer and
  # the detail stays in the terminal.
  def test_an_internal_error_is_reported_without_its_detail
    session.define_singleton_method(:listing) { raise "secret detail" }
    response = nil
    _, err = capture_io { response = get("/api/files") }

    assert_equal 500, response.status
    assert_equal "error", json(response)["status"]
    refute_includes response.body, "secret detail"
    assert_includes err, "secret detail"
  end
end
