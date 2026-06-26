defmodule Magus.Brain.Migrations.BackfillSourcesTest do
  use Magus.DataCase, async: true

  import Magus.Generators
  import Magus.Brain.MigrationsTestHelpers, only: [insert_block!: 2]

  alias Magus.Brain
  alias Magus.Brain.Migrations.BackfillSources

  setup do
    user = generate(user())
    {:ok, brain} = Brain.create_brain(%{title: "B"}, actor: user)
    {:ok, page} = Brain.create_page(brain.id, %{title: "P"}, actor: user)
    %{user: user, brain: brain, page: page}
  end

  defp source_block(page_id, attrs) do
    {:ok,
     insert_block!(
       page_id,
       Map.merge(
         %{type: :source, content: %{"url" => "https://example.com"}},
         attrs
       )
     )}
  end

  defp list_sources(brain_id) do
    Brain.list_sources!(brain_id, authorize?: false)
  end

  describe "run_batch/1" do
    test "creates a Source row keyed by (brain_id, url) for each :source block", %{
      page: page,
      brain: brain
    } do
      {:ok, _} =
        source_block(page.id, %{
          content: %{
            "url" => "https://example.com",
            "title" => "Example",
            "source_type" => "web"
          }
        })

      assert {:ok, 1} = BackfillSources.run_batch()

      assert [src] = list_sources(brain.id)
      assert src.url == "https://example.com"
      assert src.title == "Example"
      assert src.source_type == :web
      assert src.ingest_status == :pending
    end

    test "is idempotent: a second run on the same blocks does no work", %{page: page} do
      {:ok, _} = source_block(page.id, %{content: %{"url" => "https://example.com"}})

      assert {:ok, 1} = BackfillSources.run_batch()
      assert {:ok, 0} = BackfillSources.run_batch()
    end

    test "preserves legacy :ingested metadata as ingest_status :ingested", %{
      page: page,
      brain: brain
    } do
      {:ok, _} =
        source_block(page.id, %{
          content: %{"url" => "https://ingested.example"},
          metadata: %{"ingested" => true}
        })

      assert {:ok, 1} = BackfillSources.run_batch()

      assert [src] = list_sources(brain.id)
      assert src.ingest_status == :ingested
      assert src.ingested_at != nil
    end

    test "preserves legacy :ingestion_error metadata as ingest_status :failed", %{
      page: page,
      brain: brain
    } do
      {:ok, _} =
        source_block(page.id, %{
          content: %{"url" => "https://broken.example"},
          metadata: %{"ingestion_error" => "HTTP 404"}
        })

      assert {:ok, 1} = BackfillSources.run_batch()

      assert [src] = list_sources(brain.id)
      assert src.ingest_status == :failed
      assert src.ingest_error =~ "HTTP 404"
    end

    test "aggregates child paragraph blocks into Source.ingested_content", %{
      page: page,
      brain: brain
    } do
      {:ok, source} =
        source_block(page.id, %{content: %{"url" => "https://aggregated.example"}})

      insert_block!(page.id, %{
        type: :paragraph,
        content: %{"text" => "First paragraph"},
        parent_block_id: source.id
      })

      insert_block!(page.id, %{
        type: :paragraph,
        content: %{"text" => "Second paragraph"},
        parent_block_id: source.id
      })

      assert {:ok, 1} = BackfillSources.run_batch()

      assert [src] = list_sources(brain.id)
      assert src.ingested_content =~ "First paragraph"
      assert src.ingested_content =~ "Second paragraph"
    end

    test "tolerates legacy source_type values not in the new enum (paper/book)", %{
      page: page,
      brain: brain
    } do
      {:ok, _} =
        source_block(page.id, %{
          content: %{"url" => "https://paper.example", "source_type" => "paper"}
        })

      assert {:ok, 1} = BackfillSources.run_batch()

      assert [src] = list_sources(brain.id)
      assert src.source_type == :paper
    end

    test "skips :source blocks with nil or empty url", %{page: page} do
      {:ok, _} = source_block(page.id, %{content: %{"url" => ""}})

      assert {:ok, 0} = BackfillSources.run_batch()
    end
  end
end
