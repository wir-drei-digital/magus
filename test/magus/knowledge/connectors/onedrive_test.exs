defmodule Magus.Knowledge.Connectors.OnedriveTest do
  # async: false: overrides the global :onedrive_api_base_url Application env.
  use ExUnit.Case, async: false

  alias Magus.Knowledge.Connectors.Onedrive

  setup do
    graph = Bypass.open()
    prev = Application.get_env(:magus, :onedrive_api_base_url)
    base = "http://localhost:#{graph.port}"
    Application.put_env(:magus, :onedrive_api_base_url, base)
    on_exit(fn -> Application.put_env(:magus, :onedrive_api_base_url, prev) end)
    {:ok, graph: graph, base: base}
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end

  describe "connect/1" do
    test "creates a connection with an access token" do
      assert {:ok, conn} = Onedrive.connect(%{"access_token" => "ms-token"})
      assert conn.access_token == "ms-token"
    end

    test "fails without an access token" do
      assert {:error, :missing_access_token} = Onedrive.connect(%{})
    end

    test "fails with an empty access token" do
      assert {:error, :missing_access_token} = Onedrive.connect(%{"access_token" => ""})
    end
  end

  describe "list_folders/2" do
    test "keeps folder-facet entries and follows the absolute nextLink", %{
      graph: graph,
      base: base
    } do
      {:ok, conn} = Onedrive.connect(%{"access_token" => "tok"})

      # Page 1 of root children: one folder, one file. Points to an ABSOLUTE
      # nextLink at the Bypass host that the connector must GET verbatim.
      Bypass.expect_once(graph, "GET", "/me/drive/root/children", fn conn ->
        json(conn, 200, %{
          "@odata.nextLink" => base <> "/me/drive/root/children-page2",
          "value" => [
            %{"id" => "folderA", "name" => "Folder A", "folder" => %{"childCount" => 2}},
            %{"id" => "file1", "name" => "notes.txt", "file" => %{"mimeType" => "text/plain"}}
          ]
        })
      end)

      # Page 2 (absolute nextLink target): another folder, no more pages.
      Bypass.expect_once(graph, "GET", "/me/drive/root/children-page2", fn conn ->
        json(conn, 200, %{
          "value" => [
            %{"id" => "folderB", "name" => "Folder B", "folder" => %{"childCount" => 0}}
          ]
        })
      end)

      assert {:ok, folders} = Onedrive.list_folders(conn, nil)
      assert length(folders) == 2

      assert %{id: "folderA", name: "Folder A", path: "/folderA"} in folders
      assert %{id: "folderB", name: "Folder B", path: "/folderB"} in folders
    end

    test "lists children of a specific folder by id", %{graph: graph} do
      {:ok, conn} = Onedrive.connect(%{"access_token" => "tok"})

      Bypass.expect_once(graph, "GET", "/me/drive/items/parent1/children", fn conn ->
        json(conn, 200, %{
          "value" => [
            %{"id" => "childF", "name" => "Sub", "folder" => %{"childCount" => 0}}
          ]
        })
      end)

      assert {:ok, [%{id: "childF"}]} = Onedrive.list_folders(conn, "parent1")
    end
  end

  describe "list_items/3" do
    test "returns the standard item shape and prefers cTag as the etag", %{graph: graph} do
      {:ok, conn} = Onedrive.connect(%{"access_token" => "tok"})

      Bypass.expect(graph, "GET", "/me/drive/items/coll/children", fn conn ->
        json(conn, 200, %{
          "value" => [
            %{
              "id" => "doc1",
              "name" => "report.pdf",
              "cTag" => "ctag-123",
              "eTag" => "etag-should-be-ignored",
              "lastModifiedDateTime" => "2026-07-09T10:00:00Z",
              "file" => %{"mimeType" => "application/pdf"}
            },
            # A folder facet: skipped from the file listing (and enqueued for
            # recursion, but this folder has no children).
            %{"id" => "sub", "name" => "Sub", "folder" => %{"childCount" => 0}}
          ]
        })
      end)

      # Recursion into the sub-folder yields no children.
      Bypass.expect_once(graph, "GET", "/me/drive/items/sub/children", fn conn ->
        json(conn, 200, %{"value" => []})
      end)

      collection = %{external_id: "coll"}
      assert {:ok, items, nil} = Onedrive.list_items(conn, collection, nil)
      assert [item] = items
      assert item.id == "doc1"
      assert item.name == "report.pdf"
      assert item.etag == "ctag-123"
      assert item.mime_type == "application/pdf"
      assert %DateTime{} = item.updated_at
    end

    test "falls back to eTag when cTag is absent", %{graph: graph} do
      {:ok, conn} = Onedrive.connect(%{"access_token" => "tok"})

      Bypass.expect(graph, "GET", "/me/drive/items/coll/children", fn conn ->
        json(conn, 200, %{
          "value" => [
            %{
              "id" => "doc2",
              "name" => "a.txt",
              "eTag" => "etag-only",
              "lastModifiedDateTime" => "2026-07-09T10:00:00Z",
              "file" => %{"mimeType" => "text/plain"}
            }
          ]
        })
      end)

      assert {:ok, [item], nil} = Onedrive.list_items(conn, %{external_id: "coll"}, nil)
      assert item.etag == "etag-only"
    end
  end

  describe "fetch_content/2" do
    test "follows Graph's 302 redirect to the download URL", %{graph: graph} do
      {:ok, conn} = Onedrive.connect(%{"access_token" => "tok"})

      Bypass.expect_once(graph, "GET", "/me/drive/items/doc1/content", fn conn ->
        conn
        |> Plug.Conn.put_resp_header(
          "location",
          "http://localhost:#{graph.port}/download/doc1"
        )
        |> Plug.Conn.resp(302, "")
      end)

      Bypass.expect_once(graph, "GET", "/download/doc1", fn conn ->
        Plug.Conn.resp(conn, 200, "the real bytes")
      end)

      assert {:ok, "the real bytes", _meta} =
               Onedrive.fetch_content(conn, %{id: "doc1", mime_type: "text/plain"})
    end
  end

  describe "detect_changes/3 bootstrap (nil cursor)" do
    test "drains all delta pages, discards items, stores the final deltaLink", %{
      graph: graph,
      base: base
    } do
      {:ok, conn} = Onedrive.connect(%{"access_token" => "tok"})

      Bypass.expect_once(graph, "GET", "/me/drive/items/coll/delta", fn conn ->
        json(conn, 200, %{
          "@odata.nextLink" => base <> "/me/drive/items/coll/delta-page2",
          "value" => [%{"id" => "existing1", "name" => "x.txt", "file" => %{}}]
        })
      end)

      Bypass.expect_once(graph, "GET", "/me/drive/items/coll/delta-page2", fn conn ->
        json(conn, 200, %{
          "@odata.deltaLink" => base <> "/me/drive/items/coll/delta?token=NEXT",
          "value" => [%{"id" => "existing2", "name" => "y.txt", "file" => %{}}]
        })
      end)

      collection = %{external_id: "coll", sync_cursor: %{}}

      assert {:ok, [], %{"sync_cursor" => delta_link}} =
               Onedrive.detect_changes(conn, collection, ~U[1970-01-01 00:00:00Z])

      assert delta_link == base <> "/me/drive/items/coll/delta?token=NEXT"
    end
  end

  describe "detect_changes/3 with a stored cursor" do
    test "maps deleted, updated, and skips folder entries; returns the new deltaLink", %{
      graph: graph,
      base: base
    } do
      {:ok, conn} = Onedrive.connect(%{"access_token" => "tok"})

      stored = base <> "/me/drive/items/coll/delta?token=CUR"
      next = base <> "/me/drive/items/coll/delta?token=CUR2"

      # The connector must GET the stored deltaLink VERBATIM.
      Bypass.expect_once(graph, "GET", "/me/drive/items/coll/delta", fn conn ->
        assert conn.query_string == "token=CUR"

        json(conn, 200, %{
          "@odata.deltaLink" => next,
          "value" => [
            %{"id" => "gone1", "name" => "removed.txt", "deleted" => %{"state" => "deleted"}},
            %{
              "id" => "upd1",
              "name" => "changed.txt",
              "cTag" => "ctag-new",
              "lastModifiedDateTime" => "2026-07-09T12:00:00Z",
              "file" => %{"mimeType" => "text/plain"}
            },
            %{"id" => "folderX", "name" => "A folder", "folder" => %{"childCount" => 0}}
          ]
        })
      end)

      collection = %{external_id: "coll", sync_cursor: %{"sync_cursor" => stored}}

      assert {:ok, changes, %{"sync_cursor" => new_cursor}} =
               Onedrive.detect_changes(conn, collection, ~U[1970-01-01 00:00:00Z])

      assert new_cursor == next
      assert length(changes) == 2

      assert %{type: :deleted, item: %{id: "gone1"}} in changes

      updated = Enum.find(changes, &(&1.type == :updated))
      assert updated.item.id == "upd1"
      assert updated.item.etag == "ctag-new"
      assert updated.item.mime_type == "text/plain"

      refute Enum.any?(changes, &(&1.item.id == "folderX"))
    end

    test "translates a 410 Gone into {:error, :cursor_reset}", %{graph: graph, base: base} do
      {:ok, conn} = Onedrive.connect(%{"access_token" => "tok"})

      stored = base <> "/me/drive/items/coll/delta?token=STALE"

      Bypass.expect_once(graph, "GET", "/me/drive/items/coll/delta", fn conn ->
        json(conn, 410, %{"error" => %{"code" => "resyncRequired"}})
      end)

      collection = %{external_id: "coll", sync_cursor: %{"sync_cursor" => stored}}

      assert {:error, :cursor_reset} =
               Onedrive.detect_changes(conn, collection, ~U[1970-01-01 00:00:00Z])
    end
  end

  describe "deletes_in_delta?/0" do
    test "is true" do
      assert Onedrive.deletes_in_delta?() == true
    end
  end

  describe "write callbacks are not supported" do
    test "register_webhook / create_item / update_item return :not_supported" do
      {:ok, conn} = Onedrive.connect(%{"access_token" => "tok"})
      assert {:error, :not_supported} = Onedrive.register_webhook(conn, %{}, "http://cb")
      assert {:error, :not_supported} = Onedrive.create_item(conn, %{}, "n", "c", %{})
      assert {:error, :not_supported} = Onedrive.update_item(conn, %{}, "id", "c", %{})
    end
  end
end
