defmodule Magus.SuperBrain.ConvergenceTest do
  @moduledoc """
  Wave 2 Task 2.4: property-equality guarantee.

  Drives N Layer 1 episodes through the incremental builder, snapshots
  the super graph, then runs a single full rebuild and asserts that
  the from-scratch super graph matches the incrementally-built one on
  every load-bearing property of every CanonicalEntity and RELATES_TO.

  ## What this protects

  Pre-Wave-2 the incremental and full paths silently drifted:

    * canonical id formulas diverged (incremental hashed first name;
      full hashed longest-name-winner)
    * `trust_tier` first-write-wins on incremental vs `max` on full
    * `embedding` first-write-wins on incremental vs `mean` on full
    * `appearance_count` was only written by incremental; full omitted
      it so the property flipped to null on every nightly

  This test exercises the exact paths that drifted and asserts they
  converge.

  Tagged `:integration` since it requires a live FalkorDB and exercises
  the full extraction pipeline.
  """

  use Magus.ResourceCase, async: false
  use Oban.Testing, repo: Magus.Repo

  import Mox

  alias Magus.SuperBrain.Workers.{BuildSuperFull, BuildSuperIncremental}

  require Ash.Query

  setup :set_mox_from_context
  setup :verify_on_exit!

  @moduletag :integration

  defp stub_unit_embeddings do
    unit_vec = [1.0 | List.duplicate(0.0, 1535)]

    Mox.stub(Magus.Embeddings.BatchEmbedderMock, :embed_many, fn texts ->
      {:ok, Enum.map(texts, fn _ -> unit_vec end)}
    end)

    Mox.stub(Magus.Embeddings.BatchEmbedderMock, :embed_one, fn _text ->
      {:ok, unit_vec}
    end)

    :ok
  end

  # Minimal LLM stub: takes the entity name + subtype and emits one
  # Alice-supports-Bob edge using whatever names the page wants.
  defp emit_pair(name_a, sub_a, name_b, sub_b, predicate) do
    fn _, _ ->
      {:ok,
       %{
         content:
           Jason.encode!(%{
             entities: [
               %{name: name_a, type: "person", subtype: sub_a, confidence: 0.9},
               %{name: name_b, type: "project", subtype: sub_b, confidence: 0.9}
             ],
             edges: [
               %{
                 subject_name: name_a,
                 object_name: name_b,
                 predicate: predicate,
                 confidence: 0.85
               }
             ]
           }),
         usage: %Magus.SuperBrain.Usage{
           model_name: "t",
           total_tokens: 1,
           input_cost: Decimal.new("0"),
           output_cost: Decimal.new("0"),
           total_cost: Decimal.new("0")
         }
       }}
    end
  end

  defp snapshot_canonicals(super_graph) do
    {:ok, result} =
      Magus.Graph.query(
        super_graph,
        """
        MATCH (c:CanonicalEntity)
        RETURN c.id, c.name, c.primary_type, c.normalized_subtype,
               c.trust_tier, c.source_count, c.embedding
        ORDER BY c.id ASC
        """
      )

    Enum.map(result.rows, fn [id, name, ptype, nsub, tier, sc, emb] ->
      %{
        id: id,
        name: name,
        primary_type: ptype,
        normalized_subtype: nsub,
        trust_tier: tier,
        source_count: parse_number(sc, 0.0),
        embedding: parse_embedding(emb)
      }
    end)
  end

  defp snapshot_relations(super_graph) do
    {:ok, result} =
      Magus.Graph.query(
        super_graph,
        """
        MATCH (a:CanonicalEntity)-[r:RELATES_TO]->(b:CanonicalEntity)
        RETURN a.id, b.id, r.predicate, r.confidence,
               r.appearance_count, r.contested
        ORDER BY a.id, b.id
        """
      )

    Enum.map(result.rows, fn [from, to, pred, conf, ac, contested] ->
      %{
        from: from,
        to: to,
        predicate: pred,
        confidence: parse_number(conf, 0.0),
        appearance_count: parse_number(ac, 0.0),
        contested: contested_truthy?(contested)
      }
    end)
  end

  defp contested_truthy?(true), do: true
  defp contested_truthy?("true"), do: true
  defp contested_truthy?(_), do: false

  defp parse_number(nil, default), do: default
  defp parse_number(n, _default) when is_number(n), do: n * 1.0

  defp parse_number(s, default) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> default
    end
  end

  defp parse_number(_, default), do: default

  defp parse_embedding(nil), do: []
  defp parse_embedding([]), do: []
  defp parse_embedding(list) when is_list(list), do: list

  defp parse_embedding(s) when is_binary(s) do
    s
    |> String.trim_leading("<")
    |> String.trim_trailing(">")
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn part ->
      case Float.parse(part) do
        {f, _} -> f
        :error -> 0.0
      end
    end)
  end

  defp parse_embedding(_), do: []

  # Sum-of-absolute-difference per dimension. Used as a tolerance metric
  # since the running-mean update and the from-scratch mean can drift by
  # floating-point noise.
  defp embeddings_close?([], []), do: true
  defp embeddings_close?(_, []), do: false
  defp embeddings_close?([], _), do: false

  defp embeddings_close?(a, b) when length(a) == length(b) do
    Enum.zip(a, b)
    |> Enum.all?(fn {x, y} -> abs(x - y) < 1.0e-6 end)
  end

  defp embeddings_close?(_, _), do: false

  test "incremental + N episodes converges with a from-scratch full rebuild" do
    :ok = stub_unit_embeddings()

    user = generate(user())
    brain_a = generate(brain(user_id: user.id))
    brain_b = generate(brain(user_id: user.id))

    super_graph = "super:user:#{user.id}"

    on_exit(fn ->
      Magus.Graph.drop("brain:#{brain_a.id}")
      Magus.Graph.drop("brain:#{brain_b.id}")
      Magus.Graph.drop("memories:user:#{user.id}")
      Magus.Graph.drop("files:user:#{user.id}")
      Magus.Graph.drop("drafts:user:#{user.id}")
      Magus.Graph.drop(super_graph)
    end)

    # Episode 1: Alice (user) supports Aurora (system) in brain_a.
    page_a =
      brain_page(brain_id: brain_a.id, user_id: user.id, content: "Alice supports Aurora.")

    expect(
      Magus.SuperBrain.LLMMock,
      :complete,
      emit_pair("Alice", "user", "Aurora", "system", "supports")
    )

    :ok = perform_job(Magus.SuperBrain.Workers.ExtractBrainPage, %{"resource_id" => page_a.id})
    Oban.drain_queue(queue: :super_brain_extraction, with_safety: false)

    # Initial full build seeds the SuperGraph row + read-set snapshot
    # so the next incremental can run without drift.
    :ok =
      perform_job(BuildSuperFull, %{
        "accessor_type" => "user",
        "user_id" => user.id,
        "workspace_id" => nil
      })

    # Episode 2: Alice (user) supports Aurora (system) again, from
    # brain_b. Same subtypes so KNN + bucket collide on the existing
    # canonicals; promote_canonical bumps source_count and updates
    # the running-mean embedding.
    page_b =
      brain_page(brain_id: brain_b.id, user_id: user.id, content: "Alice supports Aurora again.")

    expect(
      Magus.SuperBrain.LLMMock,
      :complete,
      emit_pair("Alice", "user", "Aurora", "system", "supports")
    )

    :ok = perform_job(Magus.SuperBrain.Workers.ExtractBrainPage, %{"resource_id" => page_b.id})
    Oban.drain_queue(queue: :super_brain_extraction, with_safety: false)

    :ok =
      perform_job(BuildSuperIncremental, %{
        "accessor_type" => "user",
        "user_id" => user.id,
        "workspace_id" => nil,
        "trigger_episode_id" => nil
      })

    inc_canonicals = snapshot_canonicals(super_graph)
    inc_relations = snapshot_relations(super_graph)

    # Now rebuild from scratch and snapshot again.
    :ok =
      perform_job(BuildSuperFull, %{
        "accessor_type" => "user",
        "user_id" => user.id,
        "workspace_id" => nil
      })

    full_canonicals = snapshot_canonicals(super_graph)
    full_relations = snapshot_relations(super_graph)

    # Same canonical ids.
    assert Enum.map(inc_canonicals, & &1.id) == Enum.map(full_canonicals, & &1.id)

    # Per-canonical scalar equality (id, name, primary_type,
    # normalized_subtype, trust_tier, source_count).
    Enum.zip(inc_canonicals, full_canonicals)
    |> Enum.each(fn {a, b} ->
      assert a.id == b.id
      assert a.name == b.name
      assert a.primary_type == b.primary_type
      assert a.normalized_subtype == b.normalized_subtype
      assert a.trust_tier == b.trust_tier
      assert a.source_count == b.source_count

      assert embeddings_close?(a.embedding, b.embedding),
             "embeddings drifted beyond 1e-6 tolerance for canonical #{a.id}"
    end)

    # Same RELATES_TO edges with equal predicate, appearance_count, contested.
    assert length(inc_relations) == length(full_relations)

    Enum.zip(inc_relations, full_relations)
    |> Enum.each(fn {a, b} ->
      assert a.from == b.from
      assert a.to == b.to
      assert a.predicate == b.predicate
      assert a.appearance_count == b.appearance_count
      assert a.contested == b.contested
    end)
  end
end
