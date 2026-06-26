defmodule Magus.Agents.Plugins.Support.PreflightLlmOptsTest do
  @moduledoc """
  DB-free unit tests for the pure `Preflight.build_llm_opts/2` helper that
  injects the sticky `openrouter_session_id` (OpenRouter session id ==
  conversation id) into the conversation's sampling settings. Kept in a plain
  `ExUnit.Case` (no `DataCase`) so it runs without a database.
  """
  use ExUnit.Case, async: true

  alias Magus.Agents.Plugins.Support.Preflight

  describe "build_llm_opts/2" do
    test "injects openrouter_session_id as an atom key, preserving existing settings" do
      opts = Preflight.build_llm_opts(%{"temperature" => 0.7}, "conv-123")

      assert opts[:openrouter_session_id] == "conv-123"
      # Existing settings are kept intact (string key untouched).
      assert opts["temperature"] == 0.7
    end

    test "works when sampling settings are nil" do
      opts = Preflight.build_llm_opts(nil, "conv-abc")

      assert opts == %{openrouter_session_id: "conv-abc"}
    end

    test "merges alongside atom-keyed sampling settings" do
      opts = Preflight.build_llm_opts(%{temperature: 0.5}, "conv-xyz")

      assert opts[:openrouter_session_id] == "conv-xyz"
      assert opts[:temperature] == 0.5
    end

    test "omits the key (rather than passing nil) when the conversation id is missing" do
      assert Preflight.build_llm_opts(%{temperature: 0.5}, nil) == %{temperature: 0.5}
      assert Preflight.build_llm_opts(nil, nil) == %{}
      assert Preflight.build_llm_opts(%{}, "") == %{}
    end
  end

  describe "maybe_session_id/2 (provider gating)" do
    # openrouter_session_id is only valid for the OpenRouter provider's option
    # schema. For any other provider, ReqLLM's NimbleOptions.validate! raises
    # "unknown options" — so the session id MUST only be attached for
    # :openrouter models. These tests lock that gate.

    test "returns the conversation id for an OpenRouter-provider model" do
      assert Preflight.maybe_session_id(%{api_provider: :openrouter}, "conv-1") == "conv-1"
    end

    test "tolerates a string api_provider value" do
      assert Preflight.maybe_session_id(%{api_provider: "openrouter"}, "conv-1") == "conv-1"
    end

    test "returns nil for :publicai (Swiss Apertus) — would otherwise crash the request" do
      assert Preflight.maybe_session_id(%{api_provider: :publicai}, "conv-1") == nil
    end

    test "returns nil for :openrouter_citations (Perplexity Sonar)" do
      assert Preflight.maybe_session_id(%{api_provider: :openrouter_citations}, "conv-1") == nil
    end

    test "returns nil when the model is nil or has no api_provider" do
      assert Preflight.maybe_session_id(nil, "conv-1") == nil
      assert Preflight.maybe_session_id(%{}, "conv-1") == nil
    end

    test "end-to-end: a non-OpenRouter model yields llm_opts without the session key" do
      session_id = Preflight.maybe_session_id(%{api_provider: :publicai}, "conv-1")
      opts = Preflight.build_llm_opts(%{temperature: 0.5}, session_id)

      refute Map.has_key?(opts, :openrouter_session_id)
      assert opts == %{temperature: 0.5}
    end
  end
end
