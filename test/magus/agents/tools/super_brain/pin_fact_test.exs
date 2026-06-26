defmodule Magus.Agents.Tools.SuperBrain.PinFactTest do
  use Magus.ResourceCase, async: false
  use Oban.Testing, repo: Magus.Repo

  alias Magus.Agents.Tools.SuperBrain.PinFact

  describe "run/2" do
    test "enqueues IngestBrainPin for two accessible pages" do
      user = generate(user())
      brain = generate(brain(user_id: user.id))
      a = brain_page(brain_id: brain.id, user_id: user.id, title: "Alpha", content: "a")
      b = brain_page(brain_id: brain.id, user_id: user.id, title: "Beta", content: "b")

      assert {:ok, %{ok: true}} =
               PinFact.run(
                 %{source_page_id: a.id, target_page_id: b.id, predicate: "supports"},
                 %{user_id: user.id}
               )

      assert_enqueued(
        worker: Magus.SuperBrain.Workers.IngestBrainPin,
        args: %{
          "source_page_id" => a.id,
          "target_page_id" => b.id,
          "predicate" => "supports",
          "user_id" => user.id
        }
      )
    end

    test "returns an error when the source page is not accessible" do
      user = generate(user())
      other = generate(user())
      brain = generate(brain(user_id: other.id))
      a = brain_page(brain_id: brain.id, user_id: other.id, title: "Alpha", content: "a")
      b = brain_page(brain_id: brain.id, user_id: other.id, title: "Beta", content: "b")

      assert {:ok, %{error: _}} =
               PinFact.run(
                 %{source_page_id: a.id, target_page_id: b.id, predicate: "supports"},
                 %{user_id: user.id}
               )

      refute_enqueued(worker: Magus.SuperBrain.Workers.IngestBrainPin)
    end

    test "returns an error and enqueues nothing when pages are in different brains" do
      user = generate(user())
      brain_a = generate(brain(user_id: user.id))
      brain_b = generate(brain(user_id: user.id))
      a = brain_page(brain_id: brain_a.id, user_id: user.id, title: "Alpha", content: "a")
      b = brain_page(brain_id: brain_b.id, user_id: user.id, title: "Beta", content: "b")

      assert {:ok, %{error: _}} =
               PinFact.run(
                 %{source_page_id: a.id, target_page_id: b.id, predicate: "supports"},
                 %{user_id: user.id}
               )

      refute_enqueued(worker: Magus.SuperBrain.Workers.IngestBrainPin)
    end
  end
end
