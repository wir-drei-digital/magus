defmodule Magus.MCP.RegistryEntryTest do
  use ExUnit.Case, async: true

  alias Magus.MCP.RegistryEntry

  defp raw_entry(remotes, opts \\ []) do
    %{
      "name" => opts[:name] || "ai.smithery/smithery-ai-github",
      "title" => opts[:title],
      "description" => "GitHub MCP server",
      "version" => opts[:version] || "1.0.0",
      "repository" => %{"url" => "https://github.com/example/repo", "source" => "github"},
      "remotes" => remotes,
      "_meta" => %{
        "io.modelcontextprotocol.registry/official" => %{"status" => opts[:status] || "active"}
      }
    }
  end

  test "normalizes a streamable-http remote into an entry" do
    assert {:ok, entry} =
             RegistryEntry.from_raw(
               raw_entry([%{"type" => "streamable-http", "url" => "https://srv.example/mcp"}])
             )

    assert entry.registry_name == "ai.smithery/smithery-ai-github"
    assert entry.display_name == "Smithery Ai Github"
    assert entry.transport == :streamable_http
    assert entry.endpoint_url == "https://srv.example/mcp"
    assert entry.repository_url == "https://github.com/example/repo"
    assert entry.auth_type == :none
  end

  test "prefers streamable-http over sse when both are present" do
    remotes = [
      %{"type" => "sse", "url" => "https://srv.example/sse"},
      %{"type" => "streamable-http", "url" => "https://srv.example/mcp"}
    ]

    assert {:ok, entry} = RegistryEntry.from_raw(raw_entry(remotes))
    assert entry.transport == :streamable_http
    assert entry.endpoint_url == "https://srv.example/mcp"
  end

  test "falls back to sse when that is the only remote" do
    assert {:ok, entry} =
             RegistryEntry.from_raw(
               raw_entry([%{"type" => "sse", "url" => "https://srv.example/sse"}])
             )

    assert entry.transport == :sse
  end

  test "skips packages-only (stdio) servers with no remotes" do
    raw = %{"name" => "io.github.foo/bar", "packages" => [%{"registryType" => "npm"}]}
    assert :skip = RegistryEntry.from_raw(raw)
  end

  test "skips non-active entries" do
    raw =
      raw_entry([%{"type" => "streamable-http", "url" => "https://x/mcp"}], status: "deprecated")

    assert :skip = RegistryEntry.from_raw(raw)
  end

  test "infers static_header auth and extracts template vars from required headers" do
    remotes = [
      %{
        "type" => "streamable-http",
        "url" => "https://srv.example/mcp",
        "headers" => [
          %{
            "name" => "Authorization",
            "value" => "Bearer {api_key}",
            "isRequired" => true,
            "isSecret" => true
          }
        ]
      }
    ]

    assert {:ok, entry} = RegistryEntry.from_raw(raw_entry(remotes))
    assert entry.auth_type == :static_header

    assert [%{name: "Authorization", vars: ["api_key"], required: true, secret: true}] =
             entry.required_headers
  end

  test "infers oauth when required headers carry no fillable placeholder" do
    # GitHub's official remote MCP requires an Authorization header injected by an
    # OAuth flow, not a user-typed secret — there is no `{placeholder}` to fill.
    remotes = [
      %{
        "type" => "streamable-http",
        "url" => "https://api.githubcopilot.com/mcp/",
        "headers" => [
          %{"name" => "Authorization", "value" => "Bearer", "isRequired" => true}
        ]
      }
    ]

    assert {:ok, entry} = RegistryEntry.from_raw(raw_entry(remotes))
    assert entry.auth_type == :oauth
  end

  test "infers none when there are no required headers" do
    remotes = [
      %{
        "type" => "streamable-http",
        "url" => "https://srv.example/mcp",
        "headers" => [
          %{"name" => "X-Optional", "value" => "{maybe}", "isRequired" => false}
        ]
      }
    ]

    assert {:ok, entry} = RegistryEntry.from_raw(raw_entry(remotes))
    assert entry.auth_type == :none
  end

  test "biases to static_header when a fillable header is mixed with a bare one" do
    # One required header is user-fillable (has a placeholder); another required
    # header is bare. The fillable path wins so the user gets a secret form.
    remotes = [
      %{
        "type" => "streamable-http",
        "url" => "https://srv.example/mcp",
        "headers" => [
          %{"name" => "Authorization", "value" => "Bearer {api_key}", "isRequired" => true},
          %{"name" => "X-Injected", "value" => "static-token", "isRequired" => true}
        ]
      }
    ]

    assert {:ok, entry} = RegistryEntry.from_raw(raw_entry(remotes))
    assert entry.auth_type == :static_header
  end

  test "accepts the nested {server, _meta} shape" do
    nested = %{
      "server" => %{
        "name" => "io.github.acme/widget",
        "remotes" => [%{"type" => "streamable-http", "url" => "https://acme/mcp"}]
      },
      "_meta" => %{"io.modelcontextprotocol.registry/official" => %{"status" => "active"}}
    }

    assert {:ok, entry} = RegistryEntry.from_raw(nested)
    assert entry.registry_name == "io.github.acme/widget"
    assert entry.display_name == "Widget"
  end

  test "prefers the registry title over the reverse-DNS name" do
    assert {:ok, entry} =
             RegistryEntry.from_raw(
               raw_entry([%{"type" => "streamable-http", "url" => "https://srv.example/mcp"}],
                 name: "ac.inference.sh/mcp",
                 title: "inference.sh"
               )
             )

    # Without this, the reverse-DNS last segment "mcp" would render as "Mcp".
    assert entry.display_name == "inference.sh"
  end

  test "derives a name without a title, dropping the generic mcp token" do
    assert {:ok, entry} =
             RegistryEntry.from_raw(
               raw_entry([%{"type" => "streamable-http", "url" => "https://srv.example/mcp"}],
                 name: "ac.tandem/docs-mcp"
               )
             )

    assert entry.display_name == "Docs"
  end
end
