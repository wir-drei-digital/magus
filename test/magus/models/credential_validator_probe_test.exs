defmodule Magus.Models.CredentialValidatorProbeTest do
  use ExUnit.Case, async: false
  alias Magus.Models.CredentialValidator

  defp provider(attrs) do
    Map.merge(
      %{req_llm_id: "openai", base_url: nil, api_key: "sk-test", owner_user_id: "u"},
      attrs
    )
  end

  setup do
    Req.Test.stub(CredentialValidator, fn conn ->
      case Plug.Conn.get_req_header(conn, "authorization") do
        ["Bearer sk-good"] ->
          Req.Test.json(conn, %{"data" => [%{"id" => "gpt-4o"}, %{"id" => "gpt-4o-mini"}]})

        _ ->
          conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"error" => "unauthorized"})
      end
    end)

    Application.put_env(:magus, :credential_probe_req_options,
      plug: {Req.Test, CredentialValidator}
    )

    on_exit(fn -> Application.delete_env(:magus, :credential_probe_req_options) end)
    :ok
  end

  test "valid key probes to {:valid, ids} and validate/1 maps to :valid" do
    p = provider(%{api_key: "sk-good"})
    assert {:valid, ids} = CredentialValidator.probe(p)
    assert "gpt-4o" in ids
    assert CredentialValidator.validate(p) == :valid
  end

  test "401 maps to :invalid" do
    p = provider(%{api_key: "sk-bad"})
    assert CredentialValidator.probe(p) == :invalid
    assert CredentialValidator.validate(p) == :invalid
  end

  test "transport failure maps to :error" do
    Application.put_env(:magus, :credential_probe_req_options,
      plug: {Req.Test, CredentialValidator}
    )

    Req.Test.stub(CredentialValidator, fn conn ->
      Req.Test.transport_error(conn, :timeout)
    end)

    assert CredentialValidator.probe(provider(%{})) == :error
  end

  test "configured validator fun still overrides" do
    Application.put_env(:magus, :credential_validator, fn _ -> :invalid end)
    on_exit(fn -> Application.delete_env(:magus, :credential_validator) end)
    assert CredentialValidator.validate(provider(%{api_key: "sk-good"})) == :invalid
  end
end
