defmodule Magus.Knowledge.Connectors.KdriveTest do
  # async: false: overrides the global :kdrive_api_base_url Application env.
  use ExUnit.Case, async: false

  alias Magus.Knowledge.Connectors.Kdrive

  setup do
    api = Bypass.open()
    prev = Application.get_env(:magus, :kdrive_api_base_url)
    base = "http://localhost:#{api.port}"
    Application.put_env(:magus, :kdrive_api_base_url, base)
    on_exit(fn -> Application.put_env(:magus, :kdrive_api_base_url, prev) end)
    {:ok, api: api, base: base}
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end

  describe "connect/1" do
    test "creates a connection with an api token" do
      assert {:ok, conn} = Kdrive.connect(%{"api_token" => "kd-token"})
      assert conn.api_token == "kd-token"
    end

    test "fails without an api token" do
      assert {:error, :missing_api_token} = Kdrive.connect(%{})
    end

    test "fails with an empty api token" do
      assert {:error, :missing_api_token} = Kdrive.connect(%{"api_token" => ""})
    end
  end

  describe "list_folders/2 with nil path (drives)" do
    test "maps each drive to a composite-root folder", %{api: api} do
      {:ok, conn} = Kdrive.connect(%{"api_token" => "tok"})

      Bypass.expect_once(api, "GET", "/2/drive", fn conn ->
        json(conn, 200, %{
          "data" => [
            %{"id" => 111, "name" => "Team Drive"},
            %{"id" => 222, "name" => "Personal"}
          ]
        })
      end)

      assert {:ok, folders} = Kdrive.list_folders(conn, nil)
      assert length(folders) == 2

      assert %{id: "111:root", name: "Team Drive", path: "/111"} in folders
      assert %{id: "222:root", name: "Personal", path: "/222"} in folders
    end
  end

  describe "list_folders/2 with a composite id (directories)" do
    test "lists only child directories, translating :root to file id 1", %{api: api} do
      {:ok, conn} = Kdrive.connect(%{"api_token" => "tok"})

      Bypass.expect_once(api, "GET", "/3/drive/111/files/1/files", fn conn ->
        json(conn, 200, %{
          "data" => [
            %{"id" => 10, "name" => "Reports", "type" => "dir"},
            %{"id" => 11, "name" => "notes.txt", "type" => "file"}
          ]
        })
      end)

      assert {:ok, folders} = Kdrive.list_folders(conn, "111:root")
      assert [%{id: "111:10", name: "Reports", path: "/111/10"}] = folders
    end

    test "lists child directories under a non-root file id", %{api: api} do
      {:ok, conn} = Kdrive.connect(%{"api_token" => "tok"})

      Bypass.expect_once(api, "GET", "/3/drive/111/files/10/files", fn conn ->
        json(conn, 200, %{
          "data" => [
            %{"id" => 20, "name" => "Sub", "type" => "dir"}
          ]
        })
      end)

      assert {:ok, [%{id: "111:20"}]} = Kdrive.list_folders(conn, "111:10")
    end
  end

  describe "list_items/3" do
    test "recurses into subdirectories, aggregating files with composite ids and revised_at etags",
         %{api: api} do
      {:ok, conn} = Kdrive.connect(%{"api_token" => "tok"})

      # Root of the collection: one file + one subdir.
      Bypass.expect_once(api, "GET", "/3/drive/111/files/1/files", fn conn ->
        json(conn, 200, %{
          "data" => [
            %{
              "id" => 100,
              "name" => "top.pdf",
              "type" => "file",
              "mime_type" => "application/pdf",
              "revised_at" => 1_720_000_000
            },
            %{"id" => 50, "name" => "Sub", "type" => "dir"}
          ]
        })
      end)

      # The subdirectory: one more file.
      Bypass.expect_once(api, "GET", "/3/drive/111/files/50/files", fn conn ->
        json(conn, 200, %{
          "data" => [
            %{
              "id" => 101,
              "name" => "child.txt",
              "type" => "file",
              "mime_type" => "text/plain",
              "revised_at" => 1_720_000_500
            }
          ]
        })
      end)

      collection = %{external_id: "111:1"}
      assert {:ok, items, nil} = Kdrive.list_items(conn, collection, nil)
      assert length(items) == 2

      top = Enum.find(items, &(&1.name == "top.pdf"))
      assert top.id == "111:100"
      assert top.etag == "1720000000"
      assert top.mime_type == "application/pdf"
      assert %DateTime{} = top.updated_at
      assert DateTime.to_unix(top.updated_at) == 1_720_000_000

      child = Enum.find(items, &(&1.name == "child.txt"))
      assert child.id == "111:101"
      assert child.etag == "1720000500"
      assert child.mime_type == "text/plain"
    end

    test "falls back to updated_at when revised_at is absent, and default mime type", %{api: api} do
      {:ok, conn} = Kdrive.connect(%{"api_token" => "tok"})

      Bypass.expect_once(api, "GET", "/3/drive/111/files/1/files", fn conn ->
        json(conn, 200, %{
          "data" => [
            %{"id" => 100, "name" => "x", "type" => "file", "updated_at" => 1_720_000_777}
          ]
        })
      end)

      assert {:ok, [item], nil} = Kdrive.list_items(conn, %{external_id: "111:1"}, nil)
      assert item.etag == "1720000777"
      assert item.mime_type == "application/octet-stream"
    end
  end

  describe "fetch_content/2" do
    test "sends a Bearer token and returns the binary body", %{api: api} do
      {:ok, conn} = Kdrive.connect(%{"api_token" => "secret-token"})

      Bypass.expect_once(api, "GET", "/2/drive/111/files/100/download", fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer secret-token"]
        Plug.Conn.resp(conn, 200, "the real bytes")
      end)

      assert {:ok, "the real bytes", _meta} =
               Kdrive.fetch_content(conn, %{id: "111:100", mime_type: "application/pdf"})
    end
  end

  describe "rate limiting" do
    test "honors a 429 Retry-After once, then succeeds", %{api: api} do
      {:ok, conn} = Kdrive.connect(%{"api_token" => "tok"})

      agent = start_supervised!({Agent, fn -> 0 end})

      Bypass.expect(api, "GET", "/2/drive", fn conn ->
        n = Agent.get_and_update(agent, fn n -> {n, n + 1} end)

        if n == 0 do
          conn
          |> Plug.Conn.put_resp_header("retry-after", "1")
          |> Plug.Conn.resp(429, "slow down")
        else
          json(conn, 200, %{"data" => [%{"id" => 111, "name" => "Drive"}]})
        end
      end)

      assert {:ok, [%{id: "111:root"}]} = Kdrive.list_folders(conn, nil)
      assert Agent.get(agent, & &1) == 2
    end
  end

  describe "detect_changes/3 and write callbacks" do
    test "detect_changes returns :not_supported (fallback sync path)" do
      {:ok, conn} = Kdrive.connect(%{"api_token" => "tok"})

      assert {:error, :not_supported} =
               Kdrive.detect_changes(conn, %{external_id: "111:1"}, ~U[1970-01-01 00:00:00Z])
    end

    test "register_webhook / create_item / update_item return :not_supported" do
      {:ok, conn} = Kdrive.connect(%{"api_token" => "tok"})
      assert {:error, :not_supported} = Kdrive.register_webhook(conn, %{}, "http://cb")
      assert {:error, :not_supported} = Kdrive.create_item(conn, %{}, "n", "c", %{})
      assert {:error, :not_supported} = Kdrive.update_item(conn, %{}, "id", "c", %{})
    end
  end
end
