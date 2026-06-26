defmodule Magus.Capabilities.Search.ExaTest do
  @moduledoc """
  The Exa adapter owns its HTTP transport (self-contained, like the Spider crawl
  adapter) and honors `:magus, :exa_req_options` for `Req.Test` injection.
  """
  # async: false — mutates EXA_API_KEY (OS env) and the :exa_req_options app env.
  use ExUnit.Case, async: false

  alias Magus.Capabilities.Search.Exa

  setup do
    original_key = System.get_env("EXA_API_KEY")
    original_opts = Application.get_env(:magus, :exa_req_options)

    System.put_env("EXA_API_KEY", "test-key")
    Application.put_env(:magus, :exa_req_options, plug: {Req.Test, Exa})

    on_exit(fn ->
      if original_key,
        do: System.put_env("EXA_API_KEY", original_key),
        else: System.delete_env("EXA_API_KEY")

      if original_opts,
        do: Application.put_env(:magus, :exa_req_options, original_opts),
        else: Application.delete_env(:magus, :exa_req_options)
    end)

    :ok
  end

  describe "search/2" do
    test "parses results from the Exa API response" do
      Req.Test.stub(Exa, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/search"

        Req.Test.json(conn, %{
          "results" => [
            %{
              "title" => "Quantum leap",
              "url" => "https://example.com/q",
              "summary" => "A summary",
              "publishedDate" => "2024-12-15"
            }
          ]
        })
      end)

      assert {:ok, [result]} = Exa.search("quantum", num_results: 3)
      assert result.title == "Quantum leap"
      assert result.url == "https://example.com/q"
      assert result.summary == "A summary"
      assert result.published_date == "2024-12-15"
    end

    test "returns a structured http_error tuple on a non-200 response" do
      Req.Test.stub(Exa, fn conn ->
        conn
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{"error" => "boom"})
      end)

      assert {:error, {:http_error, 500, _body}} = Exa.search("q", [])
    end
  end

  describe "configured?/0" do
    test "is true when EXA_API_KEY is set" do
      System.put_env("EXA_API_KEY", "k")
      assert Exa.configured?()
    end

    test "is false when EXA_API_KEY is absent" do
      System.delete_env("EXA_API_KEY")
      refute Exa.configured?()
    end
  end
end
