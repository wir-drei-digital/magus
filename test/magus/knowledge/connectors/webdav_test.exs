defmodule Magus.Knowledge.Connectors.WebdavTest do
  # async: true is safe: the round-trip tests spin up a per-test Bypass server
  # and assert on request headers/paths; there is no shared global state.
  use ExUnit.Case, async: true

  alias Magus.Knowledge.Connectors.Webdav

  describe "connect/1" do
    test "splits base_url into origin and DAV root path" do
      config = %{
        "base_url" => "https://dav.example.com/remote/dav",
        "username" => "user",
        "password" => "pass"
      }

      assert {:ok, conn} = Webdav.connect(config)
      assert conn.origin == "https://dav.example.com"
      assert conn.root_path == "/remote/dav"
      assert conn.username == "user"
      assert conn.password == "pass"
    end

    test "strips trailing slash from base_url" do
      config = %{
        "base_url" => "https://dav.example.com/remote/dav/",
        "username" => "user",
        "password" => "pass"
      }

      assert {:ok, conn} = Webdav.connect(config)
      assert conn.root_path == "/remote/dav"
    end

    test "an origin-only base_url yields an empty root path" do
      config = %{
        "base_url" => "https://dav.example.com",
        "username" => "user",
        "password" => "pass"
      }

      assert {:ok, conn} = Webdav.connect(config)
      assert conn.origin == "https://dav.example.com"
      assert conn.root_path == ""
    end

    test "rejects a base_url without scheme or host" do
      for bad <- ["dav.example.com/remote", "ftp://dav.example.com", "https://"] do
        config = %{"base_url" => bad, "username" => "u", "password" => "p"}
        assert {:error, :invalid_base_url} = Webdav.connect(config)
      end
    end

    test "fails without credentials" do
      assert {:error, :missing_credentials} = Webdav.connect(%{})
    end

    test "fails with empty base_url" do
      config = %{"base_url" => "", "username" => "user", "password" => "pass"}
      assert {:error, :missing_credentials} = Webdav.connect(config)
    end

    test "fails with empty username" do
      config = %{
        "base_url" => "https://dav.example.com",
        "username" => "",
        "password" => "pass"
      }

      assert {:error, :missing_credentials} = Webdav.connect(config)
    end

    test "fails with empty password" do
      config = %{
        "base_url" => "https://dav.example.com",
        "username" => "user",
        "password" => ""
      }

      assert {:error, :missing_credentials} = Webdav.connect(config)
    end
  end

  describe "list_folders/2 (Bypass PROPFIND round-trip, path-bearing DAV root)" do
    setup do
      dav = Bypass.open()
      # The realistic shape: the DAV root lives under a path (ownCloud, Koofr,
      # Hetzner all do), and hrefs come back SERVER-absolute with that prefix.
      base = "http://localhost:#{dav.port}/remote.php/dav/files/user"
      {:ok, dav: dav, base: base}
    end

    test "sends Basic auth + Depth:1 to the rooted path, excludes self, strips prefix",
         %{dav: dav, base: base} do
      {:ok, conn} =
        Webdav.connect(%{
          "base_url" => base,
          "username" => "user",
          "password" => "pass"
        })

      expected_auth = "Basic " <> Base.encode64("user:pass")

      Bypass.expect_once(dav, fn conn ->
        assert conn.method == "PROPFIND"
        # Exactly ONE prefix: base path, not doubled.
        assert conn.request_path == "/remote.php/dav/files/user/"
        assert Plug.Conn.get_req_header(conn, "authorization") == [expected_auth]
        assert Plug.Conn.get_req_header(conn, "depth") == ["1"]

        multistatus = """
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response>
            <d:href>/remote.php/dav/files/user/</d:href>
            <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat>
          </d:response>
          <d:response>
            <d:href>/remote.php/dav/files/user/Reports/</d:href>
            <d:propstat>
              <d:prop>
                <d:displayname>Reports</d:displayname>
                <d:resourcetype><d:collection/></d:resourcetype>
              </d:prop>
            </d:propstat>
          </d:response>
        </d:multistatus>
        """

        conn
        |> Plug.Conn.put_resp_content_type("application/xml")
        |> Plug.Conn.resp(207, multistatus)
      end)

      assert {:ok, folders} = Webdav.list_folders(conn, "/")
      # Self (the root) is excluded; the UI path is root-relative.
      assert [%{name: "Reports", path: "/Reports/", id: "/remote.php/dav/files/user/Reports/"}] =
               folders
    end

    test "works at an origin-only DAV root too", %{dav: dav} do
      {:ok, conn} =
        Webdav.connect(%{
          "base_url" => "http://localhost:#{dav.port}",
          "username" => "user",
          "password" => "pass"
        })

      Bypass.expect_once(dav, fn conn ->
        assert conn.method == "PROPFIND"
        assert conn.request_path == "/"

        multistatus = """
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response>
            <d:href>/</d:href>
            <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat>
          </d:response>
          <d:response>
            <d:href>/Reports/</d:href>
            <d:propstat>
              <d:prop>
                <d:displayname>Reports</d:displayname>
                <d:resourcetype><d:collection/></d:resourcetype>
              </d:prop>
            </d:propstat>
          </d:response>
        </d:multistatus>
        """

        conn
        |> Plug.Conn.put_resp_content_type("application/xml")
        |> Plug.Conn.resp(207, multistatus)
      end)

      assert {:ok, folders} = Webdav.list_folders(conn, "/")
      assert [%{name: "Reports", path: "/Reports/"}] = folders
    end
  end

  describe "list_items/3 (Bypass PROPFIND round-trip, path-bearing DAV root)" do
    setup do
      dav = Bypass.open()
      base = "http://localhost:#{dav.port}/remote/dav"
      {:ok, dav: dav, base: base}
    end

    test "uses collection hrefs verbatim (no double prefix) and returns files",
         %{dav: dav, base: base} do
      {:ok, conn} =
        Webdav.connect(%{
          "base_url" => base,
          "username" => "user",
          "password" => "pass"
        })

      # The collection external_id is an href from a prior PROPFIND: it
      # already carries the DAV root prefix and must be used verbatim.
      Bypass.expect_once(dav, fn conn ->
        assert conn.method == "PROPFIND"
        assert conn.request_path == "/remote/dav/Docs/"
        assert Plug.Conn.get_req_header(conn, "depth") == ["1"]

        multistatus = """
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response>
            <d:href>/remote/dav/Docs/</d:href>
            <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat>
          </d:response>
          <d:response>
            <d:href>/remote/dav/Docs/report.pdf</d:href>
            <d:propstat>
              <d:prop>
                <d:displayname>report.pdf</d:displayname>
                <d:getcontenttype>application/pdf</d:getcontenttype>
                <d:getetag>"abc123"</d:getetag>
                <d:getlastmodified>Sat, 22 Mar 2026 10:30:00 GMT</d:getlastmodified>
                <d:resourcetype/>
              </d:prop>
            </d:propstat>
          </d:response>
        </d:multistatus>
        """

        conn
        |> Plug.Conn.put_resp_content_type("application/xml")
        |> Plug.Conn.resp(207, multistatus)
      end)

      assert {:ok, items, nil} = Webdav.list_items(conn, %{path: "/remote/dav/Docs"}, nil)
      assert [item] = items
      assert item.name == "report.pdf"
      assert item.id == "/remote/dav/Docs/report.pdf"
      assert item.etag == "\"abc123\""
      assert item.mime_type == "application/pdf"
      assert %DateTime{} = item.updated_at
    end

    test "resolves a logical (non-prefixed) collection path onto the DAV root",
         %{dav: dav, base: base} do
      {:ok, conn} =
        Webdav.connect(%{
          "base_url" => base,
          "username" => "user",
          "password" => "pass"
        })

      Bypass.expect_once(dav, fn conn ->
        assert conn.method == "PROPFIND"
        assert conn.request_path == "/remote/dav/Docs/"

        multistatus = """
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response>
            <d:href>/remote/dav/Docs/</d:href>
            <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat>
          </d:response>
        </d:multistatus>
        """

        conn
        |> Plug.Conn.put_resp_content_type("application/xml")
        |> Plug.Conn.resp(207, multistatus)
      end)

      assert {:ok, [], nil} = Webdav.list_items(conn, %{path: "Docs"}, nil)
    end

    test "handles absolute-URI hrefs on the same origin", %{dav: dav, base: base} do
      {:ok, conn} =
        Webdav.connect(%{
          "base_url" => base,
          "username" => "user",
          "password" => "pass"
        })

      origin = "http://localhost:#{dav.port}"

      Bypass.expect_once(dav, fn conn ->
        multistatus = """
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response>
            <d:href>#{origin}/remote/dav/Docs/</d:href>
            <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat>
          </d:response>
          <d:response>
            <d:href>#{origin}/remote/dav/Docs/notes.txt</d:href>
            <d:propstat>
              <d:prop>
                <d:displayname>notes.txt</d:displayname>
                <d:getcontenttype>text/plain</d:getcontenttype>
                <d:resourcetype/>
              </d:prop>
            </d:propstat>
          </d:response>
        </d:multistatus>
        """

        conn
        |> Plug.Conn.put_resp_content_type("application/xml")
        |> Plug.Conn.resp(207, multistatus)
      end)

      assert {:ok, [item], nil} = Webdav.list_items(conn, %{path: "/remote/dav/Docs"}, nil)
      assert item.id == "/remote/dav/Docs/notes.txt"
    end
  end

  describe "fetch_content/2 (Bypass GET with Basic auth)" do
    setup do
      dav = Bypass.open()
      base = "http://localhost:#{dav.port}/remote/dav"
      {:ok, dav: dav, base: base}
    end

    test "GETs origin <> item id (single prefix) and returns the binary body",
         %{dav: dav, base: base} do
      {:ok, conn} =
        Webdav.connect(%{
          "base_url" => base,
          "username" => "user",
          "password" => "secret"
        })

      expected_auth = "Basic " <> Base.encode64("user:secret")

      Bypass.expect_once(dav, "GET", "/remote/dav/Docs/report.pdf", fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == [expected_auth]
        Plug.Conn.resp(conn, 200, "the real bytes")
      end)

      assert {:ok, "the real bytes", meta} =
               Webdav.fetch_content(conn, %{id: "/remote/dav/Docs/report.pdf"})

      # Member-visible metadata is root-relative.
      assert meta["path"] == "/Docs/report.pdf"
    end
  end

  describe "detect_changes/3 and write callbacks" do
    test "detect_changes returns :not_supported" do
      {:ok, conn} =
        Webdav.connect(%{
          "base_url" => "https://dav.example.com",
          "username" => "u",
          "password" => "p"
        })

      assert {:error, :not_supported} =
               Webdav.detect_changes(conn, %{path: "/"}, ~U[1970-01-01 00:00:00Z])
    end

    test "register_webhook / create_item / update_item return :not_supported" do
      {:ok, conn} =
        Webdav.connect(%{
          "base_url" => "https://dav.example.com",
          "username" => "u",
          "password" => "p"
        })

      assert {:error, :not_supported} = Webdav.register_webhook(conn, %{}, "http://cb")
      assert {:error, :not_supported} = Webdav.create_item(conn, %{}, "n", "c", %{})
      assert {:error, :not_supported} = Webdav.update_item(conn, %{}, "id", "c", %{})
    end
  end
end
