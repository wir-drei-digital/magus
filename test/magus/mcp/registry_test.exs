defmodule Magus.MCP.RegistryTest do
  # Not async: mutates the app-wide `Magus.MCP` config (`registry_base_url`) and
  # shares the process-wide ETS cache owned by the running `Magus.MCP.Registry`.
  use ExUnit.Case, async: false

  alias Magus.MCP.Registry

  setup do
    bypass = Bypass.open()
    previous = Application.get_env(:magus, Magus.MCP, [])

    Application.put_env(
      :magus,
      Magus.MCP,
      Keyword.put(previous, :registry_base_url, "http://127.0.0.1:#{bypass.port}")
    )

    on_exit(fn -> Application.put_env(:magus, Magus.MCP, previous) end)

    %{bypass: bypass}
  end

  describe "list/1 error handling" do
    test "returns {:error, :registry_unavailable} when the registry is down", %{bypass: bypass} do
      # Simulate the registry host refusing connections. Req's `retry: :transient`
      # exhausts then surfaces a transport error, which the module maps to a
      # sanitized atom rather than crashing the (long-lived) GenServer.
      Bypass.down(bypass)

      assert {:error, :registry_unavailable} = Registry.list(search: unique_search())

      # The shared Registry GenServer is still alive after the failed fetch.
      assert Process.whereis(Magus.MCP.Registry) |> Process.alive?()
    end

    test "maps a 5xx registry response to an http_error tuple", %{bypass: bypass} do
      Bypass.expect(bypass, "GET", "/v0/servers", fn conn ->
        Plug.Conn.resp(conn, 503, "upstream unavailable")
      end)

      assert {:error, {:http_error, 503}} = Registry.list(search: unique_search())
    end
  end

  describe "list/1 caching" do
    test "caches by query key so a repeat call avoids a second fetch", %{bypass: bypass} do
      search = unique_search()

      body = %{
        "servers" => [
          %{
            "name" => "io.github.acme/widget",
            "remotes" => [%{"type" => "streamable-http", "url" => "https://acme.example/mcp"}],
            "_meta" => %{
              "io.modelcontextprotocol.registry/official" => %{"status" => "active"}
            }
          }
        ],
        "metadata" => %{"nextCursor" => nil}
      }

      # `expect_once` fails the test if the endpoint is hit more than once.
      Bypass.expect_once(bypass, "GET", "/v0/servers", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)

      assert {:ok, %{entries: [entry]}} = Registry.list(search: search)
      assert entry.registry_name == "io.github.acme/widget"

      # Second call with the same query key is served from the ETS cache; if it
      # hit the network, `expect_once` would have failed.
      assert {:ok, %{entries: [^entry]}} = Registry.list(search: search)
    end
  end

  describe "list/1 multi-version dedup" do
    test "collapses multiple versions of the same server to the latest", %{bypass: bypass} do
      # The real registry lists every published version of a server as its own
      # entry (same `name`, different `version`), with `_meta…isLatest` marking
      # the current one. Uses the real WRAPPED shape (`server` nested, `_meta`
      # sibling) to also exercise that path.
      body = %{
        "servers" => [
          wrapped("ai.acme/tool", "1.0.0", false),
          wrapped("ai.acme/tool", "1.1.0", true),
          wrapped("ai.other/x", "2.0.0", true)
        ],
        "metadata" => %{"nextCursor" => nil}
      }

      Bypass.expect(bypass, "GET", "/v0/servers", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)

      assert {:ok, %{entries: entries}} = Registry.list(search: unique_search())

      # One entry per name — no duplicate registry_name (which would crash a
      # keyed list in the SPA).
      names = Enum.map(entries, & &1.registry_name)
      assert names == Enum.uniq(names)
      assert "ai.acme/tool" in names
      assert "ai.other/x" in names

      # The kept version for the multi-version server is the latest.
      acme = Enum.find(entries, &(&1.registry_name == "ai.acme/tool"))
      assert acme.version == "1.1.0"
    end
  end

  defp wrapped(name, version, is_latest) do
    %{
      "server" => %{
        "name" => name,
        "version" => version,
        "remotes" => [%{"type" => "streamable-http", "url" => "https://#{name}.example/mcp"}]
      },
      "_meta" => %{
        "io.modelcontextprotocol.registry/official" => %{
          "status" => "active",
          "isLatest" => is_latest
        }
      }
    }
  end

  # A per-test-unique search term keeps each test's cache key disjoint from the
  # shared, process-wide registry cache (and from other tests in the suite).
  defp unique_search, do: "test-#{System.unique_integer([:positive])}"
end
