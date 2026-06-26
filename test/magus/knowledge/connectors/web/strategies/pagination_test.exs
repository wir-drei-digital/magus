defmodule Magus.Knowledge.Connectors.Web.Strategies.PaginationTest do
  use ExUnit.Case, async: true

  alias Magus.Knowledge.Connectors.Web.Strategies.Pagination

  describe "parse_link_header/1" do
    test "extracts next URL from a simple Link header" do
      header = ~s(<https://api.example.com/items?page=2>; rel="next")
      assert Pagination.parse_link_header(header) == "https://api.example.com/items?page=2"
    end

    test "extracts next URL when multiple rels are present" do
      header =
        ~s(<https://api.example.com/items?page=1>; rel="prev", ) <>
          ~s(<https://api.example.com/items?page=3>; rel="next")

      assert Pagination.parse_link_header(header) == "https://api.example.com/items?page=3"
    end

    test "returns nil when no next rel present" do
      header = ~s(<https://api.example.com/items?page=1>; rel="prev")
      assert Pagination.parse_link_header(header) == nil
    end

    test "returns nil for empty string" do
      assert Pagination.parse_link_header("") == nil
    end

    test "returns nil for nil" do
      assert Pagination.parse_link_header(nil) == nil
    end

    test "handles next rel with extra whitespace" do
      header = ~s(  <https://api.example.com/page=2>  ;  rel="next"  )
      assert Pagination.parse_link_header(header) == "https://api.example.com/page=2"
    end

    test "handles next rel among many rels: first, prev, next, last" do
      header =
        ~s(<https://api.example.com/?page=1>; rel="first", ) <>
          ~s(<https://api.example.com/?page=4>; rel="prev", ) <>
          ~s(<https://api.example.com/?page=6>; rel="next", ) <>
          ~s(<https://api.example.com/?page=10>; rel="last")

      assert Pagination.parse_link_header(header) == "https://api.example.com/?page=6"
    end

    test "handles URL with complex query string" do
      header =
        ~s(<https://api.example.com/items?cursor=abc123&limit=50&format=json>; rel="next")

      assert Pagination.parse_link_header(header) ==
               "https://api.example.com/items?cursor=abc123&limit=50&format=json"
    end

    test "returns nil when header has no rel=next even if has angle bracket URL" do
      header = ~s(<https://api.example.com/items>; rel="self")
      assert Pagination.parse_link_header(header) == nil
    end
  end

  describe "extract_cursor_from_json/2" do
    test "extracts a top-level key" do
      body = %{"next" => "https://api.example.com/page=2"}
      assert Pagination.extract_cursor_from_json(body, "next") == "https://api.example.com/page=2"
    end

    test "extracts a nested key with dot notation" do
      body = %{"pagination" => %{"next" => "https://api.example.com/page=2"}}

      assert Pagination.extract_cursor_from_json(body, "pagination.next") ==
               "https://api.example.com/page=2"
    end

    test "extracts deeply nested key" do
      body = %{"meta" => %{"links" => %{"next" => "https://api.example.com/page=3"}}}

      assert Pagination.extract_cursor_from_json(body, "meta.links.next") ==
               "https://api.example.com/page=3"
    end

    test "returns nil when path does not exist" do
      body = %{"data" => [1, 2, 3]}
      assert Pagination.extract_cursor_from_json(body, "pagination.next") == nil
    end

    test "returns nil when value is nil" do
      body = %{"pagination" => %{"next" => nil}}
      assert Pagination.extract_cursor_from_json(body, "pagination.next") == nil
    end

    test "returns nil when value is empty string" do
      body = %{"pagination" => %{"next" => ""}}
      assert Pagination.extract_cursor_from_json(body, "pagination.next") == nil
    end

    test "returns nil for nil body" do
      assert Pagination.extract_cursor_from_json(nil, "next") == nil
    end

    test "returns nil when intermediate key is missing" do
      body = %{"data" => "something"}
      assert Pagination.extract_cursor_from_json(body, "pagination.links.next") == nil
    end

    test "returns nil when intermediate value is not a map" do
      body = %{"pagination" => "not_a_map"}
      assert Pagination.extract_cursor_from_json(body, "pagination.next") == nil
    end

    test "handles single key path with no dots" do
      body = %{"nextPage" => "https://api.example.com/items?page=2"}

      assert Pagination.extract_cursor_from_json(body, "nextPage") ==
               "https://api.example.com/items?page=2"
    end
  end

  describe "discover/3 behaviour compliance" do
    test "discover/3 is exported" do
      assert function_exported?(Pagination, :discover, 3)
    end

    test "parse_link_header/1 is exported" do
      assert function_exported?(Pagination, :parse_link_header, 1)
    end

    test "extract_cursor_from_json/2 is exported" do
      assert function_exported?(Pagination, :extract_cursor_from_json, 2)
    end
  end
end
