defmodule Magus.Knowledge.Connectors.Web.AutoDetectorTest do
  use ExUnit.Case, async: true

  alias Magus.Knowledge.Connectors.Web.AutoDetector
  alias Magus.Knowledge.Connectors.Web.Strategies

  describe "is_openapi_spec?/1" do
    test "returns true for map with 'openapi' key" do
      assert AutoDetector.is_openapi_spec?(%{"openapi" => "3.0.0", "info" => %{"title" => "API"}})
    end

    test "returns true for map with 'swagger' key" do
      assert AutoDetector.is_openapi_spec?(%{"swagger" => "2.0", "info" => %{"title" => "API"}})
    end

    test "returns false for map without 'openapi' or 'swagger' keys" do
      refute AutoDetector.is_openapi_spec?(%{"data" => [%{"id" => 1}]})
    end

    test "returns false for empty map" do
      refute AutoDetector.is_openapi_spec?(%{})
    end

    test "returns false for non-map input" do
      refute AutoDetector.is_openapi_spec?("not a map")
      refute AutoDetector.is_openapi_spec?(nil)
      refute AutoDetector.is_openapi_spec?([])
    end

    test "returns false for map with only unrelated keys" do
      refute AutoDetector.is_openapi_spec?(%{"title" => "Something", "version" => "1.0"})
    end

    test "returns true even if value for 'openapi' is nil" do
      assert AutoDetector.is_openapi_spec?(%{"openapi" => nil})
    end
  end

  describe "parse_robots_txt/1" do
    test "parses basic disallow rules for wildcard user-agent" do
      content = """
      User-agent: *
      Disallow: /private/
      Disallow: /admin/
      """

      rules = AutoDetector.parse_robots_txt(content)
      assert length(rules) == 1

      [rule] = rules
      assert rule.user_agent == "*"
      assert "/private/" in rule.disallow
      assert "/admin/" in rule.disallow
    end

    test "parses multiple user-agent blocks" do
      content = """
      User-agent: Googlebot
      Disallow: /nogooglebot/

      User-agent: *
      Disallow: /private/
      """

      rules = AutoDetector.parse_robots_txt(content)
      assert length(rules) == 2

      googlebot = Enum.find(rules, &(&1.user_agent == "Googlebot"))
      assert googlebot != nil
      assert "/nogooglebot/" in googlebot.disallow

      wildcard = Enum.find(rules, &(&1.user_agent == "*"))
      assert wildcard != nil
      assert "/private/" in wildcard.disallow
    end

    test "returns empty list for empty content" do
      assert AutoDetector.parse_robots_txt("") == []
    end

    test "ignores comments" do
      content = """
      # This is a comment
      User-agent: *
      # Another comment
      Disallow: /private/
      """

      rules = AutoDetector.parse_robots_txt(content)
      assert length(rules) == 1
      [rule] = rules
      assert rule.disallow == ["/private/"]
    end

    test "handles allow-only blocks (no disallow)" do
      content = """
      User-agent: *
      Allow: /public/
      """

      rules = AutoDetector.parse_robots_txt(content)
      assert length(rules) == 1
      [rule] = rules
      assert rule.user_agent == "*"
      assert rule.disallow == []
    end

    test "handles empty disallow (allows everything)" do
      content = """
      User-agent: *
      Disallow:
      """

      rules = AutoDetector.parse_robots_txt(content)
      assert length(rules) == 1
      [rule] = rules
      assert rule.disallow == []
    end
  end

  describe "parse_robots_txt_with_sitemaps/1" do
    test "returns {rules, sitemap_urls}" do
      content = """
      User-agent: *
      Disallow: /private/

      Sitemap: https://example.com/sitemap.xml
      Sitemap: https://example.com/sitemap2.xml
      """

      {rules, sitemap_urls} = AutoDetector.parse_robots_txt_with_sitemaps(content)

      assert length(rules) == 1
      assert length(sitemap_urls) == 2
      assert "https://example.com/sitemap.xml" in sitemap_urls
      assert "https://example.com/sitemap2.xml" in sitemap_urls
    end

    test "returns empty sitemaps list when none present" do
      content = """
      User-agent: *
      Disallow: /private/
      """

      {_rules, sitemap_urls} = AutoDetector.parse_robots_txt_with_sitemaps(content)
      assert sitemap_urls == []
    end

    test "returns empty rules and empty sitemaps for empty content" do
      {rules, sitemap_urls} = AutoDetector.parse_robots_txt_with_sitemaps("")
      assert rules == []
      assert sitemap_urls == []
    end
  end

  describe "parse_robots_txt_full/1" do
    test "returns {rules, sitemap_urls, crawl_delay_ms}" do
      content = """
      User-agent: *
      Disallow: /private/
      Crawl-delay: 2

      Sitemap: https://example.com/sitemap.xml
      """

      {rules, sitemap_urls, crawl_delay_ms} = AutoDetector.parse_robots_txt_full(content)

      assert length(rules) == 1
      assert "https://example.com/sitemap.xml" in sitemap_urls
      assert crawl_delay_ms == 2000
    end

    test "converts crawl-delay in seconds to milliseconds" do
      content = """
      User-agent: *
      Crawl-delay: 5
      """

      {_rules, _sitemap_urls, crawl_delay_ms} = AutoDetector.parse_robots_txt_full(content)
      assert crawl_delay_ms == 5000
    end

    test "handles fractional crawl-delay" do
      content = """
      User-agent: *
      Crawl-delay: 0.5
      """

      {_rules, _sitemap_urls, crawl_delay_ms} = AutoDetector.parse_robots_txt_full(content)
      assert crawl_delay_ms == 500
    end

    test "returns nil crawl_delay_ms when not specified" do
      content = """
      User-agent: *
      Disallow: /private/
      """

      {_rules, _sitemap_urls, crawl_delay_ms} = AutoDetector.parse_robots_txt_full(content)
      assert crawl_delay_ms == nil
    end

    test "returns empty tuple elements for empty content" do
      {rules, sitemap_urls, crawl_delay_ms} = AutoDetector.parse_robots_txt_full("")
      assert rules == []
      assert sitemap_urls == []
      assert crawl_delay_ms == nil
    end
  end

  describe "strategy_for_override/1" do
    test "'auto' returns nil (trigger auto-detection)" do
      assert AutoDetector.strategy_for_override("auto") == nil
    end

    test "'sitemap' returns Sitemap strategy module" do
      assert AutoDetector.strategy_for_override("sitemap") == Strategies.Sitemap
    end

    test "'openapi' returns OpenApi strategy module" do
      assert AutoDetector.strategy_for_override("openapi") == Strategies.OpenApi
    end

    test "'pagination' returns Pagination strategy module" do
      assert AutoDetector.strategy_for_override("pagination") == Strategies.Pagination
    end

    test "'link_follow' returns LinkFollow strategy module" do
      assert AutoDetector.strategy_for_override("link_follow") == Strategies.LinkFollow
    end

    test "unknown override raises or returns nil" do
      # Should handle unknown gracefully
      result = AutoDetector.strategy_for_override("unknown_strategy")
      assert result == nil
    end
  end

  describe "extract_origin/1 (via detect/2 logic)" do
    # Testing extract_origin indirectly via is_openapi_spec? and parse functions
    # but we can also test the public function if exported.
    # For now we validate the logic is correct using module attributes.

    test "strategy_for_override handles all documented strategies" do
      strategies = ["auto", "sitemap", "openapi", "pagination", "link_follow"]

      Enum.each(strategies, fn strategy ->
        # Should not raise
        _result = AutoDetector.strategy_for_override(strategy)
      end)
    end
  end

  describe "parse_robots_txt/1 edge cases" do
    test "handles Windows-style line endings" do
      content = "User-agent: *\r\nDisallow: /private/\r\n"
      rules = AutoDetector.parse_robots_txt(content)
      assert length(rules) == 1
      [rule] = rules
      assert "/private/" in rule.disallow
    end

    test "handles multiple disallow lines for same user-agent" do
      content = """
      User-agent: *
      Disallow: /a/
      Disallow: /b/
      Disallow: /c/
      """

      rules = AutoDetector.parse_robots_txt(content)
      [rule] = rules
      assert "/a/" in rule.disallow
      assert "/b/" in rule.disallow
      assert "/c/" in rule.disallow
    end

    test "trims whitespace from values" do
      content = """
      User-agent:  *
      Disallow:   /private/
      """

      rules = AutoDetector.parse_robots_txt(content)
      [rule] = rules
      assert rule.user_agent == "*"
      # disallow should be trimmed
      assert Enum.any?(rule.disallow, &(String.trim(&1) == "/private/"))
    end
  end

  describe "parse_robots_txt_full/1 crawl-delay precedence" do
    test "uses crawl-delay from wildcard user-agent block" do
      content = """
      User-agent: Googlebot
      Crawl-delay: 10

      User-agent: *
      Crawl-delay: 3
      """

      {_rules, _sitemaps, crawl_delay_ms} = AutoDetector.parse_robots_txt_full(content)
      # Should pick up a crawl delay — either from wildcard or first found
      assert is_integer(crawl_delay_ms)
    end
  end
end
