defmodule Magus.Knowledge.Connectors.Web.BoundaryTest do
  use ExUnit.Case, async: true

  alias Magus.Knowledge.Connectors.Web.Boundary

  describe "normalize/1" do
    test "lowercases scheme and host" do
      assert Boundary.normalize("HTTPS://Example.COM/path") == "https://example.com/path"
    end

    test "removes default https port 443" do
      assert Boundary.normalize("https://example.com:443/path") == "https://example.com/path"
    end

    test "removes default http port 80" do
      assert Boundary.normalize("http://example.com:80/path") == "http://example.com/path"
    end

    test "preserves non-default ports" do
      assert Boundary.normalize("https://example.com:8080/path") ==
               "https://example.com:8080/path"
    end

    test "removes fragment" do
      assert Boundary.normalize("https://example.com/page#section") ==
               "https://example.com/page"
    end

    test "strips utm_source tracking param" do
      assert Boundary.normalize("https://example.com/page?utm_source=google") ==
               "https://example.com/page"
    end

    test "strips utm_medium tracking param" do
      assert Boundary.normalize("https://example.com/page?utm_medium=cpc") ==
               "https://example.com/page"
    end

    test "strips utm_campaign tracking param" do
      assert Boundary.normalize("https://example.com/page?utm_campaign=spring") ==
               "https://example.com/page"
    end

    test "strips utm_* tracking params (all utm_ prefixed)" do
      assert Boundary.normalize("https://example.com/page?utm_term=test&utm_content=ad") ==
               "https://example.com/page"
    end

    test "strips ref tracking param" do
      assert Boundary.normalize("https://example.com/page?ref=homepage") ==
               "https://example.com/page"
    end

    test "strips source tracking param" do
      assert Boundary.normalize("https://example.com/page?source=email") ==
               "https://example.com/page"
    end

    test "strips fbclid tracking param" do
      assert Boundary.normalize("https://example.com/page?fbclid=abc123") ==
               "https://example.com/page"
    end

    test "strips gclid tracking param" do
      assert Boundary.normalize("https://example.com/page?gclid=xyz789") ==
               "https://example.com/page"
    end

    test "preserves non-tracking query params" do
      result = Boundary.normalize("https://example.com/search?q=elixir&page=2")

      assert result == "https://example.com/search?page=2&q=elixir" or
               result == "https://example.com/search?q=elixir&page=2"
    end

    test "removes trailing slash from non-root paths" do
      assert Boundary.normalize("https://example.com/docs/") == "https://example.com/docs"
    end

    test "preserves root path slash" do
      assert Boundary.normalize("https://example.com/") == "https://example.com/"
    end

    test "handles URL with no path" do
      assert Boundary.normalize("https://example.com") == "https://example.com"
    end

    test "strips tracking params and removes trailing slash together" do
      assert Boundary.normalize("https://example.com/docs/?utm_source=twitter&ref=home") ==
               "https://example.com/docs"
    end

    test "removes fragment and tracking params together" do
      assert Boundary.normalize("https://example.com/page?utm_source=x#section") ==
               "https://example.com/page"
    end

    test "mixed tracking and real params strips only tracking" do
      result = Boundary.normalize("https://example.com/search?q=test&utm_source=google&page=1")
      assert String.contains?(result, "q=test")
      assert String.contains?(result, "page=1")
      refute String.contains?(result, "utm_source")
    end
  end

  describe "allowed?/4" do
    @config %{
      "allowed_domains" => ["example.com"],
      "allowed_paths" => [],
      "excluded_paths" => [],
      "max_depth" => 3,
      "respect_robots_txt" => false
    }

    @robots_rules []

    test "allows a URL on the allowed domain within depth" do
      assert Boundary.allowed?("https://example.com/docs", @config, @robots_rules, 1) == true
    end

    test "rejects URLs with non-http/https scheme" do
      assert Boundary.allowed?("ftp://example.com/file", @config, @robots_rules, 0) == false
    end

    test "rejects mailto: scheme" do
      assert Boundary.allowed?("mailto:user@example.com", @config, @robots_rules, 0) == false
    end

    test "rejects URLs on disallowed domains" do
      assert Boundary.allowed?("https://other.com/page", @config, @robots_rules, 0) == false
    end

    test "rejects URLs exceeding max_depth" do
      assert Boundary.allowed?("https://example.com/page", @config, @robots_rules, 4) == false
    end

    test "allows URLs at exactly max_depth" do
      assert Boundary.allowed?("https://example.com/page", @config, @robots_rules, 3) == true
    end

    test "rejects .zip file extension" do
      assert Boundary.allowed?("https://example.com/file.zip", @config, @robots_rules, 0) ==
               false
    end

    test "rejects .exe file extension" do
      assert Boundary.allowed?("https://example.com/setup.exe", @config, @robots_rules, 0) ==
               false
    end

    test "rejects .mp4 file extension" do
      assert Boundary.allowed?("https://example.com/video.mp4", @config, @robots_rules, 0) ==
               false
    end

    test "rejects .png file extension" do
      assert Boundary.allowed?("https://example.com/image.png", @config, @robots_rules, 0) ==
               false
    end

    test "rejects .jpg file extension" do
      assert Boundary.allowed?("https://example.com/photo.jpg", @config, @robots_rules, 0) ==
               false
    end

    test "rejects .gif file extension" do
      assert Boundary.allowed?("https://example.com/anim.gif", @config, @robots_rules, 0) ==
               false
    end

    test "rejects .svg file extension" do
      assert Boundary.allowed?("https://example.com/icon.svg", @config, @robots_rules, 0) ==
               false
    end

    test "rejects .css file extension" do
      assert Boundary.allowed?("https://example.com/style.css", @config, @robots_rules, 0) ==
               false
    end

    test "rejects .js file extension" do
      assert Boundary.allowed?("https://example.com/app.js", @config, @robots_rules, 0) ==
               false
    end

    test "rejects .pdf file extension" do
      assert Boundary.allowed?("https://example.com/doc.pdf", @config, @robots_rules, 0) ==
               false
    end

    test "allows .html extension" do
      assert Boundary.allowed?("https://example.com/page.html", @config, @robots_rules, 0) ==
               true
    end

    test "allows paths with no extension" do
      assert Boundary.allowed?("https://example.com/docs/guide", @config, @robots_rules, 0) ==
               true
    end

    test "allowed_paths restricts to matching prefixes" do
      config = Map.put(@config, "allowed_paths", ["/docs/", "/api/"])
      assert Boundary.allowed?("https://example.com/docs/guide", config, @robots_rules, 0) == true
      assert Boundary.allowed?("https://example.com/blog/post", config, @robots_rules, 0) == false
    end

    test "allowed_paths empty list allows all paths" do
      config = Map.put(@config, "allowed_paths", [])
      assert Boundary.allowed?("https://example.com/anything", config, @robots_rules, 0) == true
    end

    test "excluded_paths blocks matching prefixes" do
      config = Map.put(@config, "excluded_paths", ["/internal/", "/admin/"])

      assert Boundary.allowed?("https://example.com/internal/secret", config, @robots_rules, 0) ==
               false

      assert Boundary.allowed?("https://example.com/admin/panel", config, @robots_rules, 0) ==
               false

      assert Boundary.allowed?("https://example.com/public/page", config, @robots_rules, 0) ==
               true
    end

    test "respects robots.txt disallow rules when respect_robots_txt is true" do
      config = Map.put(@config, "respect_robots_txt", true)

      robots_rules = [
        %{user_agent: "*", disallow: ["/private/", "/admin/"]}
      ]

      assert Boundary.allowed?("https://example.com/private/data", config, robots_rules, 0) ==
               false

      assert Boundary.allowed?("https://example.com/public/page", config, robots_rules, 0) ==
               true
    end

    test "ignores robots.txt when respect_robots_txt is false" do
      config = Map.put(@config, "respect_robots_txt", false)

      robots_rules = [
        %{user_agent: "*", disallow: ["/private/"]}
      ]

      assert Boundary.allowed?("https://example.com/private/data", config, robots_rules, 0) ==
               true
    end

    test "robots.txt disallow with empty list allows everything" do
      config = Map.put(@config, "respect_robots_txt", true)
      robots_rules = [%{user_agent: "*", disallow: []}]

      assert Boundary.allowed?("https://example.com/page", config, robots_rules, 0) == true
    end

    test "allows subdomains when allowed_domains includes subdomain" do
      config = Map.put(@config, "allowed_domains", ["docs.example.com"])
      assert Boundary.allowed?("https://docs.example.com/page", config, @robots_rules, 0) == true
      assert Boundary.allowed?("https://example.com/page", config, @robots_rules, 0) == false
    end

    test "multiple allowed domains" do
      config = Map.put(@config, "allowed_domains", ["example.com", "docs.example.com"])
      assert Boundary.allowed?("https://example.com/page", config, @robots_rules, 0) == true
      assert Boundary.allowed?("https://docs.example.com/page", config, @robots_rules, 0) == true
      assert Boundary.allowed?("https://other.com/page", config, @robots_rules, 0) == false
    end

    test "returns false for invalid/unparseable URLs" do
      assert Boundary.allowed?("not-a-url", @config, @robots_rules, 0) == false
      assert Boundary.allowed?("", @config, @robots_rules, 0) == false
    end
  end
end
