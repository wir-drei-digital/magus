defmodule Magus.Agents.Tools.Web.WebFetchTest do
  use ExUnit.Case, async: true

  alias Magus.Agents.Tools.Web.WebFetch

  describe "display_name/0" do
    test "returns display string" do
      assert WebFetch.display_name() == "Fetching web pages..."
    end
  end

  describe "summarize_output/1" do
    test "summarizes single page fetch" do
      output = %{results: [%{url: "https://example.com", title: "Example"}]}
      assert WebFetch.summarize_output(output) == "Fetched 1 page"
    end

    test "summarizes multiple page fetch" do
      output = %{
        results: [
          %{url: "https://example.com", title: "Example"},
          %{url: "https://example.org", title: "Example Org"}
        ]
      }

      assert WebFetch.summarize_output(output) == "Fetched 2 pages"
    end

    test "summarizes error" do
      output = %{error: "Network failure"}
      assert WebFetch.summarize_output(output) =~ "Error"
      assert WebFetch.summarize_output(output) =~ "Network failure"
    end

    test "summarizes unknown output" do
      assert WebFetch.summarize_output(%{}) == "Fetch completed"
    end
  end

  describe "system_prompt_context/0" do
    test "returns context string" do
      context = WebFetch.system_prompt_context()
      assert is_binary(context)
      assert context =~ "web_fetch"
    end
  end

  describe "run/2 validation" do
    test "returns error for empty URL list" do
      params = %{urls: []}
      assert {:ok, result} = WebFetch.run(params, %{})
      assert result.error =~ "at least one URL"
      assert result.results == []
    end

    test "returns error when more than 10 URLs provided" do
      urls = Enum.map(1..11, fn i -> "https://example#{i}.com" end)
      params = %{urls: urls}
      assert {:ok, result} = WebFetch.run(params, %{})
      assert result.error =~ "maximum of 10"
      assert result.results == []
    end

    test "returns error for invalid URL format" do
      params = %{urls: ["not-a-url"]}
      assert {:ok, result} = WebFetch.run(params, %{})
      assert result.error =~ "Invalid URL"
      assert result.results == []
    end

    test "returns error for URL without scheme" do
      params = %{urls: ["example.com"]}
      assert {:ok, result} = WebFetch.run(params, %{})
      assert result.error =~ "Invalid URL"
    end

    test "returns error for mixed valid and invalid URLs" do
      params = %{urls: ["https://valid.com", "invalid-url"]}
      assert {:ok, result} = WebFetch.run(params, %{})
      assert result.error =~ "Invalid URL"
      assert result.error =~ "invalid-url"
    end
  end

  describe "run/2 scrape" do
    setup do
      System.put_env("SPIDER_API_KEY", "test-key")
      on_exit(fn -> System.delete_env("SPIDER_API_KEY") end)
    end

    test "scrapes a single URL" do
      Req.Test.stub(WebFetch, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/scrape"

        Req.Test.json(conn, [
          %{
            "url" => "https://example.com",
            "status" => 200,
            "content" => "# Example\n\nHello world",
            "metadata" => %{"title" => "Example", "description" => "An example page"}
          }
        ])
      end)

      params = %{urls: ["https://example.com"]}
      assert {:ok, result} = WebFetch.run(params, %{})

      assert result.mode == :scrape
      assert length(result.results) == 1

      [page] = result.results
      assert page.url == "https://example.com"
      assert page.title == "Example"
      assert page.content =~ "Hello world"
    end

    test "scrapes multiple URLs" do
      Req.Test.stub(WebFetch, fn conn ->
        Req.Test.json(conn, [
          %{
            "url" => "https://example.com",
            "status" => 200,
            "content" => "# Page 1",
            "metadata" => %{"title" => "Page 1"}
          },
          %{
            "url" => "https://example.org",
            "status" => 200,
            "content" => "# Page 2",
            "metadata" => %{"title" => "Page 2"}
          }
        ])
      end)

      params = %{urls: ["https://example.com", "https://example.org"]}
      assert {:ok, result} = WebFetch.run(params, %{})

      assert result.mode == :scrape
      assert length(result.results) == 2
    end

    test "truncates content at max_content_length" do
      long_content = String.duplicate("x", 30_000)

      Req.Test.stub(WebFetch, fn conn ->
        Req.Test.json(conn, [
          %{
            "url" => "https://example.com",
            "status" => 200,
            "content" => long_content,
            "metadata" => %{}
          }
        ])
      end)

      params = %{urls: ["https://example.com"], max_content_length: 5000}
      assert {:ok, result} = WebFetch.run(params, %{})

      [page] = result.results
      assert page.content =~ "[Content truncated at 5000 characters]"
      assert byte_size(page.content) < 30_000
    end

    test "defaults to scrape mode when crawl_depth is 0" do
      Req.Test.stub(WebFetch, fn conn ->
        assert conn.request_path == "/v1/scrape"

        Req.Test.json(conn, [
          %{"url" => "https://example.com", "status" => 200, "content" => "ok", "metadata" => %{}}
        ])
      end)

      params = %{urls: ["https://example.com"], crawl_depth: 0}
      assert {:ok, result} = WebFetch.run(params, %{})
      assert result.mode == :scrape
    end

    test "handles raw JSON string response from Spider" do
      Req.Test.stub(WebFetch, fn conn ->
        # Spider sometimes returns JSON as a raw string instead of parsed
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!([
            %{
              "url" => "https://example.com",
              "status" => 200,
              "content" => "# Parsed from string",
              "metadata" => %{"title" => "String Response"}
            }
          ])
        )
      end)

      params = %{urls: ["https://example.com"]}
      assert {:ok, result} = WebFetch.run(params, %{})

      assert length(result.results) >= 1
      [page] = result.results
      assert page.content =~ "Parsed from string"
    end
  end

  describe "run/2 crawl" do
    setup do
      System.put_env("SPIDER_API_KEY", "test-key")
      on_exit(fn -> System.delete_env("SPIDER_API_KEY") end)
    end

    test "crawls with depth > 0" do
      Req.Test.stub(WebFetch, fn conn ->
        assert conn.request_path == "/v1/crawl"

        Req.Test.json(conn, [
          %{
            "url" => "https://docs.example.com",
            "status" => 200,
            "content" => "# Docs Home",
            "metadata" => %{"title" => "Docs"}
          },
          %{
            "url" => "https://docs.example.com/getting-started",
            "status" => 200,
            "content" => "# Getting Started",
            "metadata" => %{"title" => "Getting Started"}
          }
        ])
      end)

      params = %{urls: ["https://docs.example.com"], crawl_depth: 2, crawl_limit: 5}
      assert {:ok, result} = WebFetch.run(params, %{})

      assert result.mode == :crawl
      assert length(result.results) == 2
    end
  end

  describe "run/2 error handling" do
    setup do
      System.put_env("SPIDER_API_KEY", "test-key")
      on_exit(fn -> System.delete_env("SPIDER_API_KEY") end)
    end

    test "returns error when API key is missing" do
      System.delete_env("SPIDER_API_KEY")

      params = %{urls: ["https://example.com"]}
      assert {:ok, result} = WebFetch.run(params, %{})
      assert result.error =~ "SPIDER_API_KEY"
    end

    test "returns error on HTTP error response" do
      Req.Test.stub(WebFetch, fn conn ->
        Plug.Conn.send_resp(conn, 403, Jason.encode!(%{"error" => "Forbidden"}))
      end)

      params = %{urls: ["https://example.com"]}
      assert {:ok, result} = WebFetch.run(params, %{})
      assert result.error =~ "HTTP 403"
    end

    test "returns error on transport failure" do
      Req.Test.stub(WebFetch, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      params = %{urls: ["https://example.com"]}
      assert {:ok, result} = WebFetch.run(params, %{})
      assert result.error =~ "econnrefused"
    end
  end

  describe "run/2 options" do
    setup do
      System.put_env("SPIDER_API_KEY", "test-key")
      on_exit(fn -> System.delete_env("SPIDER_API_KEY") end)
    end

    test "accepts return_format option" do
      Req.Test.stub(WebFetch, fn conn ->
        Req.Test.json(conn, [
          %{
            "url" => "https://example.com",
            "status" => 200,
            "content" => "plain text",
            "metadata" => %{}
          }
        ])
      end)

      params = %{urls: ["https://example.com"], return_format: "text"}
      assert {:ok, result} = WebFetch.run(params, %{})
      assert result.mode == :scrape
    end
  end
end
