defmodule Magus.SuperBrain.Workers.ExtractBaseClaimsTest do
  @moduledoc """
  Integration coverage for claim persistence (Task 4): a successful
  extraction writes `Claim` rows tied to the episode, and superseding an
  episode deletes its prior claim rows.

  Drives `ExtractMemory` (mirrors `extract_memory_test.exs`'s setup) since
  claim persistence lives in the shared `ExtractBase` pipeline every worker
  goes through.
  """

  use Magus.ResourceCase, async: false
  use Oban.Testing, repo: Magus.Repo

  import Mox

  require Ash.Query

  alias Magus.SuperBrain.Claim
  alias Magus.SuperBrain.Episode
  alias Magus.SuperBrain.Usage
  alias Magus.SuperBrain.Workers.ExtractMemory

  setup :set_mox_from_context
  setup :verify_on_exit!

  defp on_exit_drop_graph(graph) do
    on_exit(fn -> Magus.Graph.drop(graph) end)
  end

  defp zero_usage do
    %Usage{
      model_name: "test-model",
      prompt_tokens: 5,
      completion_tokens: 5,
      total_tokens: 10,
      input_cost: Decimal.new("0"),
      output_cost: Decimal.new("0"),
      total_cost: Decimal.new("0")
    }
  end

  defp ok_extract_with_claim(_messages, _opts) do
    payload =
      Jason.encode!(%{
        "entities" => [
          %{"name" => "Aurora", "type" => "project", "confidence" => 0.9},
          %{"name" => "Q3", "type" => "date", "confidence" => 0.9}
        ],
        "claims" => [
          %{
            "subject_name" => "Aurora",
            "object_name" => "Q3",
            "predicate" => "occurs_at",
            "polarity" => "affirms",
            "claim_text" => "Aurora targets Q3.",
            "confidence" => 0.8
          }
        ]
      })

    {:ok, %{content: payload, usage: zero_usage()}}
  end

  describe "perform/1" do
    test "a successful extraction writes Claim rows tied to the episode" do
      user = generate(user())
      graph = "memories:user:#{user.id}"
      on_exit_drop_graph(graph)

      memory =
        memory(user_id: user.id, scope: :user, summary: "Aurora targets Q3")

      expect(Magus.SuperBrain.LLMMock, :complete, &ok_extract_with_claim/2)

      assert :ok = perform_job(ExtractMemory, %{"resource_id" => memory.id})

      {:ok, episode} =
        Episode
        |> Ash.Query.filter(resource_type == :memory and resource_id == ^memory.id)
        |> Ash.read_one(authorize?: false)

      assert episode.status == :extracted

      {:ok, claims} =
        Claim
        |> Ash.Query.filter(source_user_id == ^user.id)
        |> Ash.read(authorize?: false)

      assert [
               %Claim{
                 claim_text: "Aurora targets Q3.",
                 subject_key: "aurora",
                 object_key: "q3",
                 predicate: "occurs_at",
                 polarity: :affirms,
                 graph_name: ^graph,
                 episode_id: episode_id
               }
             ] = claims

      assert episode_id == episode.id
    end

    test "superseding an episode deletes its prior claim rows" do
      user = generate(user())
      graph = "memories:user:#{user.id}"
      on_exit_drop_graph(graph)

      memory =
        memory(user_id: user.id, scope: :user, summary: "Aurora targets Q3")

      expect(Magus.SuperBrain.LLMMock, :complete, &ok_extract_with_claim/2)
      assert :ok = perform_job(ExtractMemory, %{"resource_id" => memory.id})

      {:ok, first_episode} =
        Episode
        |> Ash.Query.filter(resource_type == :memory and resource_id == ^memory.id)
        |> Ash.read_one(authorize?: false)

      assert {:ok, [_claim]} =
               Claim
               |> Ash.Query.filter(episode_id == ^first_episode.id)
               |> Ash.read(authorize?: false)

      # Force a second extraction with different content so the fingerprint
      # gate does not short-circuit and the prior episode is superseded.
      Ash.update!(memory, %{summary: "Aurora targets Q4 instead"},
        action: :set,
        authorize?: false
      )

      expect(Magus.SuperBrain.LLMMock, :complete, fn _messages, _opts ->
        payload =
          Jason.encode!(%{
            "entities" => [
              %{"name" => "Aurora", "type" => "project", "confidence" => 0.9},
              %{"name" => "Q4", "type" => "date", "confidence" => 0.9}
            ],
            "claims" => [
              %{
                "subject_name" => "Aurora",
                "object_name" => "Q4",
                "predicate" => "occurs_at",
                "polarity" => "affirms",
                "claim_text" => "Aurora targets Q4 instead.",
                "confidence" => 0.8
              }
            ]
          })

        {:ok, %{content: payload, usage: zero_usage()}}
      end)

      assert :ok = perform_job(ExtractMemory, %{"resource_id" => memory.id})

      assert {:ok, []} =
               Claim
               |> Ash.Query.filter(episode_id == ^first_episode.id)
               |> Ash.read(authorize?: false)

      {:ok, current_claims} =
        Claim
        |> Ash.Query.filter(source_user_id == ^user.id)
        |> Ash.read(authorize?: false)

      assert [%Claim{claim_text: "Aurora targets Q4 instead.", subject_key: "aurora"}] =
               current_claims
    end

    test "blank content extraction (no claims key) writes no Claim rows and does not error" do
      user = generate(user())
      graph = "memories:user:#{user.id}"
      on_exit_drop_graph(graph)

      memory =
        memory(user_id: user.id, scope: :user, summary: nil, content: %{})

      # Blank raw_text short-circuits before the LLM call (see
      # `ExtractBase.run_extraction/2`), so no `LLMMock` expectation is set.
      assert :ok = perform_job(ExtractMemory, %{"resource_id" => memory.id})

      {:ok, episode} =
        Episode
        |> Ash.Query.filter(resource_type == :memory and resource_id == ^memory.id)
        |> Ash.read_one(authorize?: false)

      assert episode.status == :extracted

      assert {:ok, []} =
               Claim
               |> Ash.Query.filter(source_user_id == ^user.id)
               |> Ash.read(authorize?: false)
    end
  end
end
