defmodule Magus.Models.DefaultFlagsBackfillTest do
  use Magus.DataCase, async: false

  alias Magus.Models.DefaultFlagsBackfill
  alias Magus.Repo

  # The legacy default?/default_image?/default_video? columns have been dropped
  # from the schema. To exercise the backfill's column-reading path we add them
  # back as temporary columns for the duration of each test, mirroring the DB
  # shape the data migration runs against.
  setup do
    add_flag_columns()
    on_exit(&drop_flag_columns/0)
    :ok
  end

  defp add_flag_columns do
    for col <- ~w(default? default_image? default_video?) do
      Repo.query!(~s|ALTER TABLE models ADD COLUMN "#{col}" boolean NOT NULL DEFAULT false|)
    end
  end

  defp drop_flag_columns do
    for col <- ~w(default? default_image? default_video?) do
      Repo.query!(~s|ALTER TABLE models DROP COLUMN IF EXISTS "#{col}"|)
    end
  end

  defp set_flag(model, column) do
    Repo.query!(
      ~s|UPDATE models SET "#{column}" = true WHERE id = $1|,
      [Ecto.UUID.dump!(model.id)]
    )
  end

  defp create_model!(key) do
    Magus.Chat.Model
    |> Ash.Changeset.for_create(:create, %{
      name: "M #{key}",
      key: key,
      provider: "Test",
      context_window: 1_000
    })
    |> Ash.create!(authorize?: false)
  end

  test "backfills a default? model into a chat_default assignment" do
    model = create_model!("openrouter:flag/chat")
    set_flag(model, "default?")

    assert :ok = DefaultFlagsBackfill.run()

    assert {:ok, %{model: %{key: "openrouter:flag/chat"}}} =
             Magus.Models.get_role_assignment("chat_default", load: [:model], authorize?: false)
  end

  test "backfills image and video flags into their roles" do
    image = create_model!("openrouter:flag/image")
    video = create_model!("openrouter:flag/video")
    set_flag(image, "default_image?")
    set_flag(video, "default_video?")

    assert :ok = DefaultFlagsBackfill.run()

    assert {:ok, %{model: %{key: "openrouter:flag/image"}}} =
             Magus.Models.get_role_assignment("image_default", load: [:model], authorize?: false)

    assert {:ok, %{model: %{key: "openrouter:flag/video"}}} =
             Magus.Models.get_role_assignment("video_t2v", load: [:model], authorize?: false)
  end

  test "skips gracefully when the flag columns are already dropped" do
    # Simulate the schema-drop migration having run first: no columns to read.
    drop_flag_columns()

    assert :ok = DefaultFlagsBackfill.run()

    assert {:error, _} =
             Magus.Models.get_role_assignment("chat_default", authorize?: false)
  end

  test "is idempotent and does not overwrite an existing assignment" do
    flagged = create_model!("openrouter:flag/chat")
    set_flag(flagged, "default?")

    existing = create_model!("openrouter:already/assigned")

    {:ok, _} =
      Magus.Models.assign_role(%{role: "chat_default", model_id: existing.id},
        authorize?: false
      )

    assert :ok = DefaultFlagsBackfill.run()
    # Second run is a no-op too.
    assert :ok = DefaultFlagsBackfill.run()

    assert {:ok, %{model: %{key: "openrouter:already/assigned"}}} =
             Magus.Models.get_role_assignment("chat_default", load: [:model], authorize?: false)
  end
end
