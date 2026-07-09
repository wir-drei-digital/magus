defmodule Magus.Knowledge.Connectors.WebdavTest do
  # async: true is safe: the round-trip tests spin up a per-test Bypass server
  # and assert on request headers/paths; there is no shared global state.
  use ExUnit.Case, async: true

  alias Magus.Knowledge.Connectors.Webdav

  describe "connect/1" do
    test "creates connection with valid credentials" do
      config = %{
        "base_url" => "https://dav.example.com/remote/dav",
        "username" => "user",
        "password" => "pass"
      }

      assert {:ok, conn} = Webdav.connect(config)
      assert conn.base_url == "https://dav.example.com/remote/dav"
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
      assert conn.base_url == "https://dav.example.com/remote/dav"
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

  describe "list_folders/2 (Bypass PROPFIND round-trip)" do
    setup do
      dav = Bypass.open()
      base = "http://localhost:#{dav.port}"
      {:ok, dav: dav, base: base}
    end

    test "sends Basic auth + Depth:1 to base_url directly (no /remote.php magic)",
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
        assert conn.request_path == "/"
        assert Plug.Conn.get_req_header(conn, "authorization") == [expected_auth]
        assert Plug.Conn.get_req_header(conn, "depth") == ["1"]

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

  describe "list_items/3 (Bypass PROPFIND round-trip: folder + file with etag)" do
    setup do
      dav = Bypass.open()
      base = "http://localhost:#{dav.port}"
      {:ok, dav: dav, base: base}
    end

    test "returns files (not collections) with etag/mime/updated_at", %{dav: dav, base: base} do
      {:ok, conn} =
        Webdav.connect(%{
          "base_url" => base,
          "username" => "user",
          "password" => "pass"
        })

      # Root PROPFIND: one file + one subfolder.
      Bypass.expect_once(dav, fn conn ->
        assert conn.method == "PROPFIND"
        assert conn.request_path == "/Docs/"
        assert Plug.Conn.get_req_header(conn, "depth") == ["1"]

        multistatus = """
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response>
            <d:href>/Docs/</d:href>
            <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat>
          </d:response>
          <d:response>
            <d:href>/Docs/report.pdf</d:href>
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

      assert {:ok, items, nil} = Webdav.list_items(conn, %{path: "/Docs"}, nil)
      assert [item] = items
      assert item.name == "report.pdf"
      assert item.id == "/Docs/report.pdf"
      assert item.etag == "\"abc123\""
      assert item.mime_type == "application/pdf"
      assert %DateTime{} = item.updated_at
    end
  end

  describe "fetch_content/2 (Bypass GET with Basic auth)" do
    setup do
      dav = Bypass.open()
      base = "http://localhost:#{dav.port}"
      {:ok, dav: dav, base: base}
    end

    test "sends Basic auth header and returns the binary body", %{dav: dav, base: base} do
      {:ok, conn} =
        Webdav.connect(%{
          "base_url" => base,
          "username" => "user",
          "password" => "secret"
        })

      expected_auth = "Basic " <> Base.encode64("user:secret")

      Bypass.expect_once(dav, "GET", "/Docs/report.pdf", fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == [expected_auth]
        Plug.Conn.resp(conn, 200, "the real bytes")
      end)

      assert {:ok, "the real bytes", meta} =
               Webdav.fetch_content(conn, %{id: "/Docs/report.pdf"})

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
