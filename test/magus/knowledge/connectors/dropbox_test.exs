defmodule Magus.Knowledge.Connectors.DropboxTest do
  # async: false: overrides the global :dropbox_api_base_url / :dropbox_content_base_url Application env.
  use ExUnit.Case, async: false

  alias Magus.Knowledge.Connectors.Dropbox

  setup do
    api = Bypass.open()
    content = Bypass.open()
    prev_api = Application.get_env(:magus, :dropbox_api_base_url)
    prev_content = Application.get_env(:magus, :dropbox_content_base_url)
    api_base = "http://localhost:#{api.port}"
    content_base = "http://localhost:#{content.port}"
    Application.put_env(:magus, :dropbox_api_base_url, api_base)
    Application.put_env(:magus, :dropbox_content_base_url, content_base)

    on_exit(fn ->
      Application.put_env(:magus, :dropbox_api_base_url, prev_api)
      Application.put_env(:magus, :dropbox_content_base_url, prev_content)
    end)

    {:ok, api: api, content: content, api_base: api_base, content_base: content_base}
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end

  defp read_json_body(conn) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    {Jason.decode!(raw), conn}
  end

  describe "connect/1" do
    test "creates a connection with an access token" do
      assert {:ok, conn} = Dropbox.connect(%{"access_token" => "dbx-token"})
      assert conn.access_token == "dbx-token"
    end

    test "fails without an access token" do
      assert {:error, :missing_access_token} = Dropbox.connect(%{})
    end

    test "fails with an empty access token" do
      assert {:error, :missing_access_token} = Dropbox.connect(%{"access_token" => ""})
    end
  end

  describe "list_folders/2" do
    test "maps nil path to root \"\", keeps folder entries, follows has_more", %{api: api} do
      {:ok, conn} = Dropbox.connect(%{"access_token" => "tok"})

      Bypass.expect_once(api, "POST", "/2/files/list_folder", fn conn ->
        {body, conn} = read_json_body(conn)
        # nil path must map to the Dropbox root "".
        assert body["path"] == ""
        assert body["recursive"] == false

        json(conn, 200, %{
          "has_more" => true,
          "cursor" => "CUR1",
          "entries" => [
            %{
              ".tag" => "folder",
              "id" => "id:folderA",
              "name" => "Folder A",
              "path_lower" => "/folder a",
              "path_display" => "/Folder A"
            },
            %{
              ".tag" => "file",
              "id" => "id:file1",
              "name" => "notes.txt",
              "path_lower" => "/notes.txt",
              "path_display" => "/notes.txt",
              "content_hash" => "hash1",
              "server_modified" => "2026-07-09T10:00:00Z"
            }
          ]
        })
      end)

      Bypass.expect_once(api, "POST", "/2/files/list_folder/continue", fn conn ->
        {body, conn} = read_json_body(conn)
        assert body["cursor"] == "CUR1"

        json(conn, 200, %{
          "has_more" => false,
          "entries" => [
            %{
              ".tag" => "folder",
              "id" => "id:folderB",
              "name" => "Folder B",
              "path_lower" => "/folder b",
              "path_display" => "/Folder B"
            }
          ]
        })
      end)

      assert {:ok, folders} = Dropbox.list_folders(conn, nil)
      assert length(folders) == 2
      assert %{id: "/folder a", name: "Folder A", path: "/Folder A"} in folders
      assert %{id: "/folder b", name: "Folder B", path: "/Folder B"} in folders
    end

    test "lists a specific folder by path", %{api: api} do
      {:ok, conn} = Dropbox.connect(%{"access_token" => "tok"})

      Bypass.expect_once(api, "POST", "/2/files/list_folder", fn conn ->
        {body, conn} = read_json_body(conn)
        assert body["path"] == "/sub"

        json(conn, 200, %{
          "has_more" => false,
          "entries" => [
            %{
              ".tag" => "folder",
              "id" => "id:childF",
              "name" => "Sub",
              "path_lower" => "/sub/child",
              "path_display" => "/sub/Child"
            }
          ]
        })
      end)

      assert {:ok, [%{id: "/sub/child"}]} = Dropbox.list_folders(conn, "/sub")
    end
  end

  describe "list_items/3" do
    test "path_lower id, content_hash etag, folder skip, has_more continuation", %{api: api} do
      {:ok, conn} = Dropbox.connect(%{"access_token" => "tok"})

      Bypass.expect_once(api, "POST", "/2/files/list_folder", fn conn ->
        {body, conn} = read_json_body(conn)
        assert body["path"] == "/coll"
        assert body["recursive"] == true

        json(conn, 200, %{
          "has_more" => true,
          "cursor" => "PAGECUR",
          "entries" => [
            %{
              ".tag" => "file",
              "id" => "id:doc1",
              "name" => "report.pdf",
              "path_lower" => "/coll/report.pdf",
              "path_display" => "/coll/report.pdf",
              "content_hash" => "chash-123",
              "server_modified" => "2026-07-09T10:00:00Z"
            },
            %{
              ".tag" => "folder",
              "id" => "id:sub",
              "name" => "Sub",
              "path_lower" => "/coll/sub",
              "path_display" => "/coll/Sub"
            }
          ]
        })
      end)

      Bypass.expect_once(api, "POST", "/2/files/list_folder/continue", fn conn ->
        {body, conn} = read_json_body(conn)
        assert body["cursor"] == "PAGECUR"

        json(conn, 200, %{
          "has_more" => false,
          "entries" => [
            %{
              ".tag" => "file",
              "id" => "id:doc2",
              "name" => "b.txt",
              "path_lower" => "/coll/sub/b.txt",
              "path_display" => "/coll/sub/b.txt",
              "content_hash" => "chash-456",
              "server_modified" => "2026-07-09T11:00:00Z"
            }
          ]
        })
      end)

      collection = %{external_id: "/coll"}
      assert {:ok, items, nil} = Dropbox.list_items(conn, collection, nil)
      assert length(items) == 2

      doc1 = Enum.find(items, &(&1.id == "/coll/report.pdf"))
      assert doc1.name == "report.pdf"
      assert doc1.etag == "chash-123"
      assert doc1.mime_type == "application/octet-stream"
      assert %DateTime{} = doc1.updated_at

      doc2 = Enum.find(items, &(&1.id == "/coll/sub/b.txt"))
      assert doc2.etag == "chash-456"

      refute Enum.any?(items, &(&1.id == "/coll/sub"))
    end

    test "prefers external_path over external_id and maps \"/\" to \"\"", %{api: api} do
      {:ok, conn} = Dropbox.connect(%{"access_token" => "tok"})

      Bypass.expect_once(api, "POST", "/2/files/list_folder", fn conn ->
        {body, conn} = read_json_body(conn)
        # external_path present but "/" root maps to "".
        assert body["path"] == ""

        json(conn, 200, %{"has_more" => false, "entries" => []})
      end)

      collection = %{external_id: "id:xyz", external_path: "/"}
      assert {:ok, [], nil} = Dropbox.list_items(conn, collection, nil)
    end
  end

  describe "fetch_content/2" do
    test "downloads from the content host with the Dropbox-API-Arg header", %{content: content} do
      {:ok, conn} = Dropbox.connect(%{"access_token" => "tok"})

      Bypass.expect_once(content, "POST", "/2/files/download", fn conn ->
        # The Dropbox-API-Arg header MUST carry the JSON-encoded path.
        [arg] = Plug.Conn.get_req_header(conn, "dropbox-api-arg")
        assert Jason.decode!(arg) == %{"path" => "/coll/report.pdf"}

        Plug.Conn.resp(conn, 200, "the real bytes")
      end)

      assert {:ok, "the real bytes", _meta} =
               Dropbox.fetch_content(conn, %{id: "/coll/report.pdf"})
    end
  end

  describe "detect_changes/3 bootstrap (nil cursor)" do
    test "gets the latest cursor and returns no changes", %{api: api} do
      {:ok, conn} = Dropbox.connect(%{"access_token" => "tok"})

      Bypass.expect_once(api, "POST", "/2/files/list_folder/get_latest_cursor", fn conn ->
        {body, conn} = read_json_body(conn)
        assert body["path"] == "/coll"
        assert body["recursive"] == true

        json(conn, 200, %{"cursor" => "BOOTSTRAP_CUR"})
      end)

      collection = %{external_id: "/coll", sync_cursor: %{}}

      assert {:ok, [], %{"sync_cursor" => "BOOTSTRAP_CUR"}} =
               Dropbox.detect_changes(conn, collection, ~U[1970-01-01 00:00:00Z])
    end
  end

  describe "detect_changes/3 with a stored cursor" do
    test "maps deleted (by path_lower), updated, skips folders; loops has_more", %{api: api} do
      {:ok, conn} = Dropbox.connect(%{"access_token" => "tok"})

      Bypass.expect(api, "POST", "/2/files/list_folder/continue", fn conn ->
        {body, conn} = read_json_body(conn)

        case body["cursor"] do
          "CUR" ->
            json(conn, 200, %{
              "has_more" => true,
              "cursor" => "CUR2",
              "entries" => [
                %{
                  ".tag" => "deleted",
                  "name" => "removed.txt",
                  "path_lower" => "/coll/removed.txt"
                },
                %{
                  ".tag" => "file",
                  "id" => "id:upd1",
                  "name" => "changed.txt",
                  "path_lower" => "/coll/changed.txt",
                  "path_display" => "/coll/changed.txt",
                  "content_hash" => "chash-new",
                  "server_modified" => "2026-07-09T12:00:00Z"
                }
              ]
            })

          "CUR2" ->
            json(conn, 200, %{
              "has_more" => false,
              "cursor" => "CUR3",
              "entries" => [
                %{
                  ".tag" => "folder",
                  "id" => "id:folderX",
                  "name" => "A folder",
                  "path_lower" => "/coll/afolder",
                  "path_display" => "/coll/AFolder"
                }
              ]
            })
        end
      end)

      collection = %{external_id: "/coll", sync_cursor: %{"sync_cursor" => "CUR"}}

      assert {:ok, changes, %{"sync_cursor" => "CUR3"}} =
               Dropbox.detect_changes(conn, collection, ~U[1970-01-01 00:00:00Z])

      assert length(changes) == 2
      assert %{type: :deleted, item: %{id: "/coll/removed.txt"}} in changes

      updated = Enum.find(changes, &(&1.type == :updated))
      assert updated.item.id == "/coll/changed.txt"
      assert updated.item.etag == "chash-new"
      assert updated.item.mime_type == "application/octet-stream"

      refute Enum.any?(changes, &(&1.item.id == "/coll/afolder"))
    end

    test "translates a 409 reset body into {:error, :cursor_reset}", %{api: api} do
      {:ok, conn} = Dropbox.connect(%{"access_token" => "tok"})

      Bypass.expect_once(api, "POST", "/2/files/list_folder/continue", fn conn ->
        json(conn, 409, %{
          "error" => %{".tag" => "reset"},
          "error_summary" => "reset/..."
        })
      end)

      collection = %{external_id: "/coll", sync_cursor: %{"sync_cursor" => "STALE"}}

      assert {:error, :cursor_reset} =
               Dropbox.detect_changes(conn, collection, ~U[1970-01-01 00:00:00Z])
    end
  end

  describe "deletes_in_delta?/0" do
    test "is true" do
      assert Dropbox.deletes_in_delta?() == true
    end
  end

  describe "write callbacks are not supported" do
    test "register_webhook / create_item / update_item return :not_supported" do
      {:ok, conn} = Dropbox.connect(%{"access_token" => "tok"})
      assert {:error, :not_supported} = Dropbox.register_webhook(conn, %{}, "http://cb")
      assert {:error, :not_supported} = Dropbox.create_item(conn, %{}, "n", "c", %{})
      assert {:error, :not_supported} = Dropbox.update_item(conn, %{}, "id", "c", %{})
    end
  end
end
