defmodule Magus.Knowledge.Connectors.Web.Strategies.OpenApiTest do
  use ExUnit.Case, async: true

  alias Magus.Knowledge.Connectors.Web.Strategies.OpenApi

  # Minimal fake connection struct
  defp conn(seed_url, auth_headers \\ []) do
    %{seed_url: seed_url, auth_headers: auth_headers, robots_rules: []}
  end

  @sample_spec %{
    "openapi" => "3.0.0",
    "info" => %{"title" => "Test API", "version" => "1.0.0"},
    "servers" => [%{"url" => "https://api.example.com"}],
    "paths" => %{
      "/pages" => %{
        "get" => %{
          "operationId" => "listPages",
          "summary" => "List all pages",
          "description" => "Returns a list of pages",
          "tags" => ["Pages"],
          "parameters" => [
            %{"name" => "limit", "in" => "query", "description" => "Max results"}
          ],
          "responses" => %{
            "200" => %{"description" => "Success"}
          }
        }
      },
      "/pages/{id}" => %{
        "get" => %{
          "operationId" => "getPage",
          "summary" => "Get a page",
          "tags" => ["Pages"],
          "parameters" => [
            %{"name" => "id", "in" => "path", "description" => "Page ID"}
          ],
          "responses" => %{
            "200" => %{"description" => "Success"},
            "404" => %{"description" => "Not found"}
          }
        },
        "put" => %{
          "operationId" => "updatePage",
          "summary" => "Update a page",
          "tags" => ["Pages"]
        }
      },
      "/blog/posts" => %{
        "get" => %{
          "operationId" => "listBlogPosts",
          "summary" => "List blog posts",
          "tags" => ["Blog"],
          "responses" => %{"200" => %{"description" => "Success"}}
        },
        "post" => %{
          "operationId" => "createBlogPost",
          "summary" => "Create a blog post",
          "tags" => ["Blog"]
        }
      },
      "/media/files" => %{
        "get" => %{
          "operationId" => "listMedia",
          "summary" => "List media files",
          "tags" => ["Media"],
          "responses" => %{"200" => %{"description" => "Success"}}
        }
      },
      "/users" => %{
        "get" => %{
          "operationId" => "listUsers",
          "summary" => "List users",
          "tags" => ["Users"],
          "responses" => %{"200" => %{"description" => "Success"}}
        },
        "post" => %{
          "operationId" => "createUser",
          "tags" => ["Users"]
        }
      }
    }
  }

  # -------------------------------------------------------------------
  # parse_spec/1
  # -------------------------------------------------------------------

  describe "parse_spec/1" do
    test "parses valid JSON" do
      json = Jason.encode!(@sample_spec)
      assert {:ok, parsed} = OpenApi.parse_spec(json)
      assert parsed["openapi"] == "3.0.0"
    end

    test "parses valid YAML" do
      yaml = """
      openapi: "3.0.0"
      info:
        title: Test
        version: "1.0"
      paths: {}
      """

      assert {:ok, parsed} = OpenApi.parse_spec(yaml)
      assert parsed["openapi"] == "3.0.0"
    end

    test "returns error for invalid content" do
      assert {:error, _} = OpenApi.parse_spec("not json or yaml {{{{")
    end
  end

  # -------------------------------------------------------------------
  # extract_endpoints/2 — GET-only filtering
  # -------------------------------------------------------------------

  describe "extract_endpoints/2 — GET-only" do
    test "only returns GET endpoints" do
      {:ok, endpoints} = OpenApi.extract_endpoints(@sample_spec, %{})

      operation_ids = Enum.map(endpoints, & &1.metadata.operation_id)

      assert "listPages" in operation_ids
      assert "getPage" in operation_ids
      assert "listBlogPosts" in operation_ids
      assert "listMedia" in operation_ids
      assert "listUsers" in operation_ids

      # POST/PUT should be excluded
      refute "updatePage" in operation_ids
      refute "createBlogPost" in operation_ids
      refute "createUser" in operation_ids
    end

    test "builds full URLs from servers[0].url + path" do
      {:ok, endpoints} = OpenApi.extract_endpoints(@sample_spec, %{})

      urls = Enum.map(endpoints, & &1.url)
      assert "https://api.example.com/pages" in urls
      assert "https://api.example.com/pages/{id}" in urls
      assert "https://api.example.com/blog/posts" in urls
    end

    test "includes correct metadata" do
      {:ok, endpoints} = OpenApi.extract_endpoints(@sample_spec, %{})
      endpoint = Enum.find(endpoints, &(&1.metadata.operation_id == "listPages"))

      assert endpoint.metadata.summary == "List all pages"
      assert endpoint.metadata.tags == ["Pages"]
      assert endpoint.metadata.path == "/pages"
    end
  end

  # -------------------------------------------------------------------
  # extract_endpoints/2 — tag filtering
  # -------------------------------------------------------------------

  describe "extract_endpoints/2 — tag filtering" do
    test "include_tags filters to only those tags" do
      settings = %{"openapi" => %{"include_tags" => ["Pages"]}}
      {:ok, endpoints} = OpenApi.extract_endpoints(@sample_spec, settings)

      tags = endpoints |> Enum.flat_map(& &1.metadata.tags) |> Enum.uniq()
      assert tags == ["Pages"]
    end

    test "include_tags with multiple tags" do
      settings = %{"openapi" => %{"include_tags" => ["Pages", "Blog"]}}
      {:ok, endpoints} = OpenApi.extract_endpoints(@sample_spec, settings)

      operation_ids = Enum.map(endpoints, & &1.metadata.operation_id)
      assert "listPages" in operation_ids
      assert "listBlogPosts" in operation_ids
      refute "listMedia" in operation_ids
      refute "listUsers" in operation_ids
    end

    test "exclude_tags removes those tags" do
      settings = %{"openapi" => %{"exclude_tags" => ["Media"]}}
      {:ok, endpoints} = OpenApi.extract_endpoints(@sample_spec, settings)

      operation_ids = Enum.map(endpoints, & &1.metadata.operation_id)
      refute "listMedia" in operation_ids
      assert "listPages" in operation_ids
      assert "listBlogPosts" in operation_ids
    end

    test "include_tags takes precedence over exclude_tags" do
      # include_tags is applied first, so exclude_tags on a tag not in include_tags has no effect
      settings = %{
        "openapi" => %{
          "include_tags" => ["Pages"],
          "exclude_tags" => ["Pages"]
        }
      }

      {:ok, endpoints} = OpenApi.extract_endpoints(@sample_spec, settings)
      # include_tags => only Pages; exclude_tags then removes Pages => empty
      assert endpoints == []
    end

    test "nil include_tags means all tags" do
      settings = %{"openapi" => %{"include_tags" => nil}}
      {:ok, endpoints} = OpenApi.extract_endpoints(@sample_spec, settings)
      # all 5 GET endpoints
      assert length(endpoints) == 5
    end
  end

  # -------------------------------------------------------------------
  # extract_endpoints/2 — path filtering
  # -------------------------------------------------------------------

  describe "extract_endpoints/2 — path filtering" do
    test "include_paths filters by path prefix" do
      settings = %{"openapi" => %{"include_paths" => ["/blog"]}}
      {:ok, endpoints} = OpenApi.extract_endpoints(@sample_spec, settings)

      assert length(endpoints) == 1
      assert hd(endpoints).metadata.path == "/blog/posts"
    end

    test "exclude_paths removes matching paths" do
      settings = %{"openapi" => %{"exclude_paths" => ["/media"]}}
      {:ok, endpoints} = OpenApi.extract_endpoints(@sample_spec, settings)

      paths = Enum.map(endpoints, & &1.metadata.path)
      refute "/media/files" in paths
      assert "/pages" in paths
    end

    test "include_paths takes precedence over exclude_paths" do
      settings = %{
        "openapi" => %{
          "include_paths" => ["/pages"],
          "exclude_paths" => ["/pages"]
        }
      }

      {:ok, endpoints} = OpenApi.extract_endpoints(@sample_spec, settings)
      # include first => only /pages*; then exclude /pages* => empty
      assert endpoints == []
    end

    test "empty include_paths means all paths" do
      settings = %{"openapi" => %{"include_paths" => []}}
      {:ok, endpoints} = OpenApi.extract_endpoints(@sample_spec, settings)
      assert length(endpoints) == 5
    end
  end

  # -------------------------------------------------------------------
  # extract_endpoints/2 — filtering precedence: tags before paths
  # -------------------------------------------------------------------

  describe "extract_endpoints/2 — tag vs path precedence" do
    test "include_tags filters before include_paths" do
      # include_tags => Pages only, then include_paths /pages => still Pages only
      settings = %{
        "openapi" => %{
          "include_tags" => ["Pages"],
          "include_paths" => ["/pages"]
        }
      }

      {:ok, endpoints} = OpenApi.extract_endpoints(@sample_spec, settings)
      assert Enum.all?(endpoints, &("Pages" in &1.metadata.tags))
    end
  end

  # -------------------------------------------------------------------
  # extract_endpoints/2 — no server URL
  # -------------------------------------------------------------------

  describe "extract_endpoints/2 — server URL handling" do
    test "falls back to empty base when no servers key" do
      spec = Map.delete(@sample_spec, "servers")
      {:ok, endpoints} = OpenApi.extract_endpoints(spec, %{})
      # URLs should start with just the path
      assert Enum.any?(endpoints, &String.starts_with?(&1.url, "/pages"))
    end

    test "strips trailing slash from server URL" do
      spec = put_in(@sample_spec, ["servers"], [%{"url" => "https://api.example.com/"}])
      {:ok, endpoints} = OpenApi.extract_endpoints(spec, %{})
      urls = Enum.map(endpoints, & &1.url)
      # Should not have double slash
      refute Enum.any?(urls, &String.contains?(&1, "//pages"))
    end
  end

  # -------------------------------------------------------------------
  # format_endpoint_as_doc/3
  # -------------------------------------------------------------------

  describe "format_endpoint_as_doc/3" do
    test "generates markdown with title" do
      operation = %{
        "summary" => "List all pages",
        "description" => "Returns a list of pages.",
        "tags" => ["Pages"],
        "operationId" => "listPages",
        "parameters" => [],
        "responses" => %{"200" => %{"description" => "Success"}}
      }

      doc = OpenApi.format_endpoint_as_doc("/pages", "get", operation)
      assert String.contains?(doc, "# GET /pages")
    end

    test "includes summary and description" do
      operation = %{
        "summary" => "List all pages",
        "description" => "Returns a list of pages.",
        "tags" => ["Pages"],
        "parameters" => [],
        "responses" => %{}
      }

      doc = OpenApi.format_endpoint_as_doc("/pages", "get", operation)
      assert String.contains?(doc, "List all pages")
      assert String.contains?(doc, "Returns a list of pages.")
    end

    test "includes parameters section when present" do
      operation = %{
        "summary" => "Get page",
        "parameters" => [
          %{"name" => "id", "in" => "path", "description" => "The page ID"},
          %{"name" => "format", "in" => "query", "description" => "Response format"}
        ],
        "responses" => %{}
      }

      doc = OpenApi.format_endpoint_as_doc("/pages/{id}", "get", operation)
      assert String.contains?(doc, "Parameters")
      assert String.contains?(doc, "id")
      assert String.contains?(doc, "format")
    end

    test "includes responses section" do
      operation = %{
        "summary" => "Get page",
        "parameters" => [],
        "responses" => %{
          "200" => %{"description" => "OK"},
          "404" => %{"description" => "Not found"}
        }
      }

      doc = OpenApi.format_endpoint_as_doc("/pages/{id}", "get", operation)
      assert String.contains?(doc, "Responses")
      assert String.contains?(doc, "200")
      assert String.contains?(doc, "404")
    end

    test "includes tags line" do
      operation = %{
        "summary" => "List pages",
        "tags" => ["Pages", "Content"],
        "parameters" => [],
        "responses" => %{}
      }

      doc = OpenApi.format_endpoint_as_doc("/pages", "get", operation)
      assert String.contains?(doc, "Pages")
      assert String.contains?(doc, "Content")
    end

    test "handles missing optional fields gracefully" do
      operation = %{
        "responses" => %{"200" => %{"description" => "OK"}}
      }

      doc = OpenApi.format_endpoint_as_doc("/simple", "get", operation)
      assert String.contains?(doc, "# GET /simple")
    end
  end

  # -------------------------------------------------------------------
  # discover/3 — spec_only mode
  # -------------------------------------------------------------------

  describe "discover/3 — spec_only mode" do
    test "returns spec_content in metadata for each endpoint" do
      spec_json = Jason.encode!(@sample_spec)
      connection = conn("https://api.example.com/openapi.json")

      # Bypass HTTP by injecting the spec body via Bypass or a mock.
      # Here we test the logic directly by using discover with a pre-fetched spec stub.
      settings = %{"openapi" => %{"mode" => "spec_only"}}

      {:ok, items, nil} = OpenApi.discover_from_spec(spec_json, connection, settings, nil)

      assert length(items) > 0
      # Each item in spec_only mode should have spec_content in metadata
      assert Enum.all?(items, &Map.has_key?(&1.metadata, :spec_content))
    end

    test "spec_content is markdown string" do
      spec_json = Jason.encode!(@sample_spec)
      connection = conn("https://api.example.com/openapi.json")
      settings = %{"openapi" => %{"mode" => "spec_only"}}

      {:ok, items, nil} = OpenApi.discover_from_spec(spec_json, connection, settings, nil)

      Enum.each(items, fn item ->
        assert is_binary(item.metadata.spec_content)
        assert String.contains?(item.metadata.spec_content, "# GET ")
      end)
    end

    test "url in spec_only mode points to endpoint URL" do
      spec_json = Jason.encode!(@sample_spec)
      connection = conn("https://api.example.com/openapi.json")
      settings = %{"openapi" => %{"mode" => "spec_only"}}

      {:ok, items, nil} = OpenApi.discover_from_spec(spec_json, connection, settings, nil)
      urls = Enum.map(items, & &1.url)
      assert "https://api.example.com/pages" in urls
    end
  end

  # -------------------------------------------------------------------
  # discover/3 — content mode
  # -------------------------------------------------------------------

  describe "discover/3 — content mode" do
    test "returns endpoint URLs without spec_content in metadata" do
      spec_json = Jason.encode!(@sample_spec)
      connection = conn("https://api.example.com/openapi.json")
      settings = %{"openapi" => %{"mode" => "content"}}

      {:ok, items, nil} = OpenApi.discover_from_spec(spec_json, connection, settings, nil)

      assert length(items) > 0
      # content mode does NOT embed spec_content
      assert Enum.all?(items, fn item -> not Map.has_key?(item.metadata, :spec_content) end)
    end
  end

  # -------------------------------------------------------------------
  # discover/3 — default mode is spec_only
  # -------------------------------------------------------------------

  describe "discover/3 — default mode" do
    test "defaults to spec_only when mode not set" do
      spec_json = Jason.encode!(@sample_spec)
      connection = conn("https://api.example.com/openapi.json")
      settings = %{}

      {:ok, items, nil} = OpenApi.discover_from_spec(spec_json, connection, settings, nil)
      assert Enum.all?(items, &Map.has_key?(&1.metadata, :spec_content))
    end
  end

  # -------------------------------------------------------------------
  # discover/3 — cursor is always nil (single page)
  # -------------------------------------------------------------------

  describe "discover/3 — pagination" do
    test "returns nil cursor (single page, no pagination)" do
      spec_json = Jason.encode!(@sample_spec)
      connection = conn("https://api.example.com/openapi.json")

      {:ok, _items, cursor} = OpenApi.discover_from_spec(spec_json, connection, %{}, nil)
      assert cursor == nil
    end
  end
end
