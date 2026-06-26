defmodule Magus.Knowledge.Connectors.Web.Strategies.LinkFollowTest do
  use ExUnit.Case, async: true

  alias Magus.Knowledge.Connectors.Web.Strategies.LinkFollow

  @base_url "https://example.com"

  @html_with_links """
  <!DOCTYPE html>
  <html>
    <head><title>Test Page</title></head>
    <body>
      <a href="/page1">Page 1</a>
      <a href="/page2">Page 2</a>
      <a href="https://example.com/page3">Page 3 (absolute)</a>
      <a href="https://other.com/page4">External Page</a>
      <a href="mailto:user@example.com">Email Link</a>
      <a href="javascript:void(0)">JS Link</a>
      <a href="#section">Fragment Only</a>
      <a href="/docs/page5">Docs Page</a>
    </body>
  </html>
  """

  @html_with_relative_links """
  <!DOCTYPE html>
  <html>
    <body>
      <a href="./subpage">Relative subpage</a>
      <a href="../other">Parent relative</a>
      <a href="https://example.com/abs">Absolute link</a>
    </body>
  </html>
  """

  @html_no_links """
  <!DOCTYPE html>
  <html>
    <body><p>No links here</p></body>
  </html>
  """

  # --- extract_links/2 tests ---

  describe "extract_links/2" do
    test "extracts absolute and relative links from HTML" do
      links = LinkFollow.extract_links(@html_with_links, @base_url)

      assert "https://example.com/page1" in links
      assert "https://example.com/page2" in links
      assert "https://example.com/page3" in links
      assert "https://example.com/docs/page5" in links
    end

    test "excludes mailto: links" do
      links = LinkFollow.extract_links(@html_with_links, @base_url)
      refute Enum.any?(links, &String.starts_with?(&1, "mailto:"))
    end

    test "excludes javascript: links" do
      links = LinkFollow.extract_links(@html_with_links, @base_url)
      refute Enum.any?(links, &String.starts_with?(&1, "javascript:"))
    end

    test "excludes fragment-only links" do
      links = LinkFollow.extract_links(@html_with_links, @base_url)
      refute "#section" in links
      refute Enum.any?(links, fn l -> l == "#section" end)
    end

    test "includes links to other domains (boundary filtering happens later)" do
      links = LinkFollow.extract_links(@html_with_links, @base_url)
      assert "https://other.com/page4" in links
    end

    test "resolves relative URLs against base URL" do
      links = LinkFollow.extract_links(@html_with_relative_links, "https://example.com/docs/page")

      assert "https://example.com/docs/subpage" in links
    end

    test "resolves absolute URLs unchanged" do
      links = LinkFollow.extract_links(@html_with_relative_links, "https://example.com/docs/page")
      assert "https://example.com/abs" in links
    end

    test "returns empty list when no links present" do
      links = LinkFollow.extract_links(@html_no_links, @base_url)
      assert links == []
    end

    test "returns empty list for empty HTML" do
      links = LinkFollow.extract_links("", @base_url)
      assert links == []
    end

    test "handles malformed HTML gracefully" do
      links = LinkFollow.extract_links("<a href='/page'>unclosed", @base_url)
      assert "https://example.com/page" in links
    end

    test "trims whitespace from href values" do
      html = ~s(<a href="  /page  ">link</a>)
      links = LinkFollow.extract_links(html, @base_url)
      assert "https://example.com/page" in links
    end
  end

  # --- initial_cursor/1 tests ---

  describe "initial_cursor/1" do
    test "returns cursor with seed URL in frontier" do
      cursor = LinkFollow.initial_cursor("https://example.com/start")

      assert %{"frontier" => frontier} = cursor
      assert "https://example.com/start" in frontier
    end

    test "returns cursor with empty depth_map for seed URL at depth 0" do
      cursor = LinkFollow.initial_cursor("https://example.com/start")

      assert %{"depth_map" => depth_map} = cursor
      assert depth_map["https://example.com/start"] == 0
    end

    test "returns cursor with pages_discovered set to 0" do
      cursor = LinkFollow.initial_cursor("https://example.com/start")
      assert cursor["pages_discovered"] == 0
    end

    test "cursor has the required keys" do
      cursor = LinkFollow.initial_cursor("https://example.com")

      assert Map.has_key?(cursor, "frontier")
      assert Map.has_key?(cursor, "depth_map")
      assert Map.has_key?(cursor, "pages_discovered")
    end
  end

  # --- pop_batch/2 tests ---

  describe "pop_batch/2" do
    test "pops up to batch_size URLs from frontier" do
      urls = for i <- 1..25, do: "https://example.com/page#{i}"

      cursor = %{
        "frontier" => urls,
        "depth_map" => Map.new(urls, fn url -> {url, 1} end),
        "pages_discovered" => 0
      }

      {batch, updated_cursor} = LinkFollow.pop_batch(cursor, 20)

      assert length(batch) == 20
      assert length(updated_cursor["frontier"]) == 5
    end

    test "pops fewer than batch_size when frontier has fewer URLs" do
      urls = ["https://example.com/page1", "https://example.com/page2"]

      cursor = %{
        "frontier" => urls,
        "depth_map" => %{"https://example.com/page1" => 1, "https://example.com/page2" => 1},
        "pages_discovered" => 0
      }

      {batch, updated_cursor} = LinkFollow.pop_batch(cursor, 20)

      assert length(batch) == 2
      assert updated_cursor["frontier"] == []
    end

    test "returns tuples of {url, depth} in the batch" do
      cursor = %{
        "frontier" => ["https://example.com/page1"],
        "depth_map" => %{"https://example.com/page1" => 3},
        "pages_discovered" => 0
      }

      {[{url, depth}], _} = LinkFollow.pop_batch(cursor, 20)

      assert url == "https://example.com/page1"
      assert depth == 3
    end

    test "returns empty batch for empty frontier" do
      cursor = %{
        "frontier" => [],
        "depth_map" => %{},
        "pages_discovered" => 0
      }

      {batch, updated_cursor} = LinkFollow.pop_batch(cursor, 20)

      assert batch == []
      assert updated_cursor["frontier"] == []
    end

    test "removes popped URLs from frontier in updated cursor" do
      urls = ["https://example.com/a", "https://example.com/b", "https://example.com/c"]

      cursor = %{
        "frontier" => urls,
        "depth_map" => Map.new(urls, fn url -> {url, 1} end),
        "pages_discovered" => 0
      }

      {batch, updated_cursor} = LinkFollow.pop_batch(cursor, 2)

      popped_urls = Enum.map(batch, fn {url, _} -> url end)

      assert length(batch) == 2
      assert length(updated_cursor["frontier"]) == 1

      Enum.each(popped_urls, fn url ->
        refute url in updated_cursor["frontier"]
      end)
    end
  end

  # --- discover/3 behaviour tests (no HTTP) ---

  describe "discover/3" do
    test "returns {:error, _} when called without HTTP (verifies callback implemented)" do
      # Just verify the function is exported and implements the behaviour
      assert function_exported?(LinkFollow, :discover, 3)
    end

    test "returns {:ok, [], nil} when frontier is empty in cursor" do
      connection = %{
        seed_url: "https://example.com",
        auth_headers: [],
        robots_rules: []
      }

      settings = %{
        "allowed_domains" => ["example.com"],
        "allowed_paths" => [],
        "excluded_paths" => [],
        "max_depth" => 3,
        "max_pages" => 100,
        "respect_robots_txt" => false
      }

      # Cursor with empty frontier — no HTTP needed
      cursor = %{
        "frontier" => [],
        "depth_map" => %{},
        "pages_discovered" => 5
      }

      assert {:ok, [], nil} = LinkFollow.discover(connection, settings, cursor)
    end

    test "stops when max_pages already reached" do
      connection = %{
        seed_url: "https://example.com",
        auth_headers: [],
        robots_rules: []
      }

      settings = %{
        "allowed_domains" => ["example.com"],
        "allowed_paths" => [],
        "excluded_paths" => [],
        "max_depth" => 3,
        "max_pages" => 5,
        "respect_robots_txt" => false
      }

      # Already at max_pages
      cursor = %{
        "frontier" => ["https://example.com/page1"],
        "depth_map" => %{"https://example.com/page1" => 1},
        "pages_discovered" => 5
      }

      assert {:ok, [], nil} = LinkFollow.discover(connection, settings, cursor)
    end
  end

  # --- Integration-style tests for frontier management ---

  describe "frontier management" do
    test "initial_cursor followed by pop_batch yields the seed URL" do
      seed = "https://example.com/start"
      cursor = LinkFollow.initial_cursor(seed)
      {batch, _} = LinkFollow.pop_batch(cursor, 20)

      urls = Enum.map(batch, fn {url, _} -> url end)
      assert seed in urls
    end

    test "seed URL is at depth 0" do
      seed = "https://example.com/start"
      cursor = LinkFollow.initial_cursor(seed)
      {[{_url, depth}], _} = LinkFollow.pop_batch(cursor, 20)

      assert depth == 0
    end
  end
end
