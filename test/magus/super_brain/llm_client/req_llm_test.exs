defmodule Magus.SuperBrain.LLMClient.ReqLLMTest do
  # async: false because the test swaps the global :llm_client app env.
  use ExUnit.Case, async: false

  alias Magus.SuperBrain.LLMClient.ReqLLM, as: Adapter

  # Captures the structured-output schema the adapter hands to the provider,
  # then short-circuits so no network is involved. Runs in the caller's
  # process, so send/2 to self() reaches the test.
  defmodule CapturingClient do
    def generate_object(model, _context, schema, _opts) do
      send(self(), {:generate_object, model, schema})
      {:error, :short_circuit}
    end
  end

  test "requests the Claims v1 shape (claims, not edges) from the provider" do
    previous = Application.get_env(:magus, :llm_client)
    Application.put_env(:magus, :llm_client, CapturingClient)
    on_exit(fn -> Application.put_env(:magus, :llm_client, previous) end)

    messages = [
      %{role: "system", content: "extract"},
      %{role: "user", content: "Aurora uses FalkorDB."}
    ]

    assert {:error, :short_circuit} = Adapter.complete(messages, model: "openrouter:test-model")

    assert_received {:generate_object, "openrouter:test-model", schema}
    rendered = inspect(schema, limit: :infinity)

    # The extraction parser requires entities + claims; a schema that still
    # requests edges makes every REAL extraction fail with
    # :unexpected_schema while mock-based tests keep passing. Pin the shape.
    assert rendered =~ "claims"
    refute rendered =~ "edges"

    for field <- ~w(subject_name predicate object_name polarity claim_text confidence) do
      assert rendered =~ field, "claim schema is missing the #{field} field"
    end
  end
end
