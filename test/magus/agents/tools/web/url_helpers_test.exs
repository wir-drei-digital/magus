defmodule Magus.Agents.Tools.Web.UrlHelpersTest do
  use ExUnit.Case, async: true

  alias Magus.Agents.Tools.Web.UrlHelpers

  describe "valid_url?/1" do
    test "returns true for valid http URL" do
      assert UrlHelpers.valid_url?("http://example.com")
    end

    test "returns true for valid https URL" do
      assert UrlHelpers.valid_url?("https://example.com")
    end

    test "returns true for URL with path" do
      assert UrlHelpers.valid_url?("https://example.com/path/to/page")
    end

    test "returns true for URL with query params" do
      assert UrlHelpers.valid_url?("https://example.com/search?q=test")
    end

    test "returns false for URL without scheme" do
      refute UrlHelpers.valid_url?("example.com")
    end

    test "returns false for URL with unsupported scheme" do
      refute UrlHelpers.valid_url?("ftp://example.com")
    end

    test "returns false for empty string" do
      refute UrlHelpers.valid_url?("")
    end

    test "returns false for non-string" do
      refute UrlHelpers.valid_url?(nil)
      refute UrlHelpers.valid_url?(123)
    end

    test "returns false for URL without host" do
      refute UrlHelpers.valid_url?("https://")
    end
  end
end
