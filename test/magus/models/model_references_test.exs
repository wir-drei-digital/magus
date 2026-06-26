defmodule Magus.Models.ModelReferencesTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  alias Magus.Models.ModelReferences

  test "counts referencing rows per category" do
    model =
      Magus.Chat.Model
      |> Ash.Changeset.for_create(:create, %{
        name: "Ref Target",
        key: "openrouter:ref/target",
        provider: "T",
        context_window: 1_000
      })
      |> Ash.create!(authorize?: false)

    counts = ModelReferences.counts(model.id)
    assert counts.conversations == 0
    assert counts.routing_slots == 0
    assert counts.role_assignments == 0

    {:ok, _} =
      Magus.Models.assign_role(%{role: "summary", model_id: model.id}, authorize?: false)

    assert ModelReferences.counts(model.id).role_assignments == 1
    assert ModelReferences.total(model.id) == 1
  end

  test "conversations count covers the OR across all three model columns" do
    model =
      Magus.Chat.Model
      |> Ash.Changeset.for_create(:create, %{
        name: "Ref Target 2",
        key: "openrouter:ref/target-2",
        provider: "T",
        context_window: 1_000
      })
      |> Ash.create!(authorize?: false)

    user = generate(user())

    # One conversation references the model via selected_model_id ...
    generate(conversation(actor: user, selected_model_id: model.id))

    # ... and a second via selected_image_model_id (set_image_model action).
    generate(conversation(actor: user))
    |> Ash.Changeset.for_update(:set_image_model, %{selected_image_model_id: model.id},
      actor: user
    )
    |> Ash.update!()

    # A routing slot references the model too.
    routing_slot(model_id: model.id, specialty: :coding, tier: :complex)

    counts = ModelReferences.counts(model.id)
    assert counts.conversations == 2
    assert counts.routing_slots == 1
    assert counts.role_assignments == 0
    assert ModelReferences.total(model.id) == 3
  end
end
