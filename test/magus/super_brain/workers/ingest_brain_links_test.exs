defmodule Magus.SuperBrain.Workers.IngestBrainLinksTest do
  @moduledoc """
  Verifies `Magus.SuperBrain.Workers.IngestBrainLinks` materializes a page's
  `[[wikilinks]]` (from the `brain_page_links` index) into the brain's Layer-1
  FalkorDB graph as `:instruction`-tier `:mentions` edges between the pages'
  `document` entities.
  """

  use Magus.ResourceCase, async: false
  use Oban.Testing, repo: Magus.Repo

  import Mox

  require Ash.Query

  alias Magus.SuperBrain.Episode
  alias Magus.SuperBrain.Workers.IngestBrainLinks

  setup :set_mox_from_context
  setup :verify_on_exit!

  defp on_exit_drop_graph(brain_id) do
    on_exit(fn -> Magus.Graph.drop("brain:#{brain_id}") end)
  end

  # Returns the [trust_tier, predicate] rows for every RELATES_TO edge from
  # `source_title` in the brain graph, sorted by the target name.
  defp mentions_edges(brain_id, source_title) do
    {:ok, result} =
      Magus.Graph.query(
        "brain:#{brain_id}",
        """
        MATCH (s:Entity {name: $name})-[r:RELATES_TO]->(t:Entity)
        RETURN t.name, r.predicate, r.trust_tier ORDER BY t.name
        """,
        %{name: source_title}
      )

    result.rows
  end

  describe "perform/1" do
    test "writes :mentions instruction-tier edges for a page's wikilinks" do
      user = generate(user())
      brain = generate(brain(user_id: user.id))
      on_exit_drop_graph(brain.id)

      brain_page(brain_id: brain.id, user_id: user.id, title: "Beta", content: "b")
      brain_page(brain_id: brain.id, user_id: user.id, title: "Gamma", content: "g")

      alpha =
        brain_page(
          brain_id: brain.id,
          user_id: user.id,
          title: "Alpha",
          content: "links to [[Beta]] and [[Gamma]]"
        )

      assert :ok = perform_job(IngestBrainLinks, %{"page_id" => alpha.id})

      assert mentions_edges(brain.id, "Alpha") == [
               ["Beta", "mentions", "instruction"],
               ["Gamma", "mentions", "instruction"]
             ]

      # Exactly one :extracted :brain_links episode for the source page.
      {:ok, episode} =
        Episode
        |> Ash.Query.filter(
          resource_type == :brain_links and resource_id == ^alpha.id and status == :extracted
        )
        |> Ash.read_one(authorize?: false)

      assert episode.graph_name == "brain:#{brain.id}"
      assert episode.source_weight == 1.0

      # The source entity carries the curated link extractor prefix so inline
      # canonicalize never merges it.
      {:ok, ext} =
        Magus.Graph.query(
          "brain:#{brain.id}",
          "MATCH (e:Entity {name: 'Alpha'}) RETURN e.extractor"
        )

      assert [[extractor]] = ext.rows
      assert String.starts_with?(extractor, "brain_links_ingest")
    end

    test "re-running after a link is removed supersedes: removed edge gone, other stays" do
      user = generate(user())
      brain = generate(brain(user_id: user.id))
      on_exit_drop_graph(brain.id)
      {:ok, owner} = Magus.Accounts.get_user(user.id, authorize?: false)

      brain_page(brain_id: brain.id, user_id: user.id, title: "Beta", content: "b")
      brain_page(brain_id: brain.id, user_id: user.id, title: "Gamma", content: "g")

      alpha =
        brain_page(
          brain_id: brain.id,
          user_id: user.id,
          title: "Alpha",
          content: "links to [[Beta]] and [[Gamma]]"
        )

      assert :ok = perform_job(IngestBrainLinks, %{"page_id" => alpha.id})

      assert mentions_edges(brain.id, "Alpha") == [
               ["Beta", "mentions", "instruction"],
               ["Gamma", "mentions", "instruction"]
             ]

      # Remove the [[Gamma]] link, keep [[Beta]].
      replace_page_body(alpha, "links to [[Beta]] only", owner)
      assert :ok = perform_job(IngestBrainLinks, %{"page_id" => alpha.id})

      assert mentions_edges(brain.id, "Alpha") == [["Beta", "mentions", "instruction"]]

      # Exactly one :extracted episode (the prior one was superseded).
      {:ok, extracted} =
        Episode
        |> Ash.Query.filter(resource_type == :brain_links and resource_id == ^alpha.id)
        |> Ash.read(authorize?: false)

      assert Enum.count(extracted, &(&1.status == :extracted)) == 1
    end

    test "fingerprint-skip: unchanged links + re-run leaves one :extracted episode" do
      user = generate(user())
      brain = generate(brain(user_id: user.id))
      on_exit_drop_graph(brain.id)

      brain_page(brain_id: brain.id, user_id: user.id, title: "Beta", content: "b")

      alpha =
        brain_page(
          brain_id: brain.id,
          user_id: user.id,
          title: "Alpha",
          content: "links to [[Beta]]"
        )

      assert :ok = perform_job(IngestBrainLinks, %{"page_id" => alpha.id})
      # Second run with identical links is a no-op (fingerprint gate).
      assert :ok = perform_job(IngestBrainLinks, %{"page_id" => alpha.id})

      {:ok, all} =
        Episode
        |> Ash.Query.filter(resource_type == :brain_links and resource_id == ^alpha.id)
        |> Ash.read(authorize?: false)

      # Only the single :extracted row exists; the gate skipped before any
      # supersede/create on the second run.
      assert length(all) == 1
      assert hd(all).status == :extracted
    end

    test "skips self-links and missing targets" do
      user = generate(user())
      brain = generate(brain(user_id: user.id))
      on_exit_drop_graph(brain.id)

      brain_page(brain_id: brain.id, user_id: user.id, title: "Beta", content: "b")

      # Alpha links to itself, a missing page, and a real page (Beta).
      alpha =
        brain_page(
          brain_id: brain.id,
          user_id: user.id,
          title: "Alpha",
          content: "self [[Alpha]], missing [[Nope]], real [[Beta]]"
        )

      assert :ok = perform_job(IngestBrainLinks, %{"page_id" => alpha.id})

      # Only the Beta edge survives: the self-link and the unresolved
      # [[Nope]] target are dropped.
      assert mentions_edges(brain.id, "Alpha") == [["Beta", "mentions", "instruction"]]
    end
  end

  describe "Page.update_body enqueues IngestBrainLinks" do
    test "saving a page body enqueues IngestBrainLinks with the page id" do
      user = generate(user())
      brain = generate(brain(user_id: user.id))
      {:ok, owner} = Magus.Accounts.get_user(user.id, authorize?: false)

      page = brain_page(brain_id: brain.id, user_id: user.id, title: "Alpha", content: "")
      replace_page_body(page, "some body", owner)

      assert_enqueued(
        worker: IngestBrainLinks,
        args: %{"page_id" => page.id}
      )
    end
  end
end
