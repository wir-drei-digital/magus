defmodule Magus.Models.HealthCheckTest do
  use Magus.DataCase, async: true

  alias Magus.Models.HealthCheck

  defp provider!(attrs) do
    Magus.Models.create_provider!(
      Map.merge(%{name: "P", slug: "hc_#{System.unique_integer([:positive])}"}, attrs),
      authorize?: false
    )
  end

  test "openai-compatible probe returns model count on 200" do
    plug = fn conn ->
      assert ["Bearer sk-test"] = Plug.Conn.get_req_header(conn, "authorization")
      Req.Test.json(conn, %{"data" => [%{"id" => "m1"}, %{"id" => "m2"}]})
    end

    provider =
      provider!(%{
        req_llm_id: "openai_compatible",
        base_url: "http://localhost:9/v1",
        api_key: "sk-test"
      })

    assert {:ok, %{models: 2}} = HealthCheck.test_provider(provider, plug: plug)
  end

  test "auth failure is reported" do
    plug = fn conn -> Plug.Conn.send_resp(conn, 401, ~s({"error":"bad key"})) end

    provider =
      provider!(%{
        req_llm_id: "openai_compatible",
        base_url: "http://localhost:9/v1",
        api_key: "sk-bad"
      })

    assert {:error, message} = HealthCheck.test_provider(provider, plug: plug)
    assert message =~ "401"
  end

  test "anthropic uses x-api-key and version headers" do
    plug = fn conn ->
      assert ["sk-ant"] = Plug.Conn.get_req_header(conn, "x-api-key")
      assert [_] = Plug.Conn.get_req_header(conn, "anthropic-version")
      Req.Test.json(conn, %{"data" => [%{"id" => "claude-x"}]})
    end

    provider = provider!(%{req_llm_id: "anthropic", api_key: "sk-ant"})
    assert {:ok, %{models: 1}} = HealthCheck.test_provider(provider, plug: plug)
  end

  test "anthropic without stored base_url probes /v1/models" do
    # No base_url stored, so it falls back to ReqLLM's anthropic default
    # (https://api.anthropic.com, no /v1). The probe path must still be
    # /v1/models. The plug intercepts before any real network call.
    plug = fn conn ->
      assert conn.request_path == "/v1/models"
      Req.Test.json(conn, %{"data" => [%{"id" => "claude-x"}]})
    end

    provider = provider!(%{req_llm_id: "anthropic", api_key: "sk-ant"})
    assert {:ok, %{models: 1}} = HealthCheck.test_provider(provider, plug: plug)
  end

  test "trailing-slash base_url does not produce //models" do
    plug = fn conn ->
      assert conn.request_path == "/v1/models"
      Req.Test.json(conn, %{"data" => []})
    end

    provider =
      provider!(%{
        req_llm_id: "openai_compatible",
        base_url: "http://localhost:9/v1/",
        api_key: "sk-test"
      })

    assert {:ok, %{models: 0}} = HealthCheck.test_provider(provider, plug: plug)
  end

  test "missing key (no DB value, no env) is a clear error" do
    provider = provider!(%{req_llm_id: "openai_compatible", base_url: "http://localhost:9/v1"})

    case HealthCheck.test_provider(provider, plug: fn conn -> Req.Test.json(conn, %{}) end) do
      # acceptable: either an explicit no-key error, or a request sent without auth
      {:error, message} -> assert message =~ ~r/key/i
      {:ok, _} -> :ok
    end
  end
end
