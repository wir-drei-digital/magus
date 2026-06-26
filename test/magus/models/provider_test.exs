defmodule Magus.Models.ProviderTest do
  use Magus.ResourceCase, async: true

  setup do
    # Clear seeded catalog rows (and their referencing rows) so slug-collision
    # tests start clean. Rolled back after the test.
    Magus.DataCase.clear_catalog!()
    :ok
  end

  describe "Provider CRUD" do
    setup do
      %{admin: create_admin()}
    end

    test "creates a built-in provider with slug defaulting semantics", %{admin: admin} do
      assert {:ok, provider} =
               Magus.Models.create_provider(
                 %{
                   name: "OpenRouter",
                   slug: "openrouter",
                   req_llm_id: "openrouter"
                 },
                 actor: admin
               )

      assert provider.enabled?
      assert provider.base_url == nil
      assert provider.api_key == nil
    end

    test "creates a custom provider with base_url and encrypted api_key", %{admin: admin} do
      assert {:ok, provider} =
               Magus.Models.create_provider(
                 %{
                   name: "Local vLLM",
                   slug: "local_vllm",
                   req_llm_id: "openai_compatible",
                   base_url: "http://localhost:8000/v1",
                   api_key: "sk-secret"
                 },
                 actor: admin
               )

      # api_key round-trips decrypted through the Ash type
      assert provider.api_key == "sk-secret"

      # but is not plaintext at rest
      %{rows: [[stored]]} =
        Magus.Repo.query!("SELECT api_key FROM model_providers WHERE id = $1", [
          Ecto.UUID.dump!(provider.id)
        ])

      refute stored == "sk-secret"
    end

    test "slug is unique", %{admin: admin} do
      {:ok, _} =
        Magus.Models.create_provider(%{name: "A", slug: "dup", req_llm_id: "openrouter"},
          actor: admin
        )

      assert {:error, %Ash.Error.Invalid{}} =
               Magus.Models.create_provider(%{name: "B", slug: "dup", req_llm_id: "openrouter"},
                 actor: admin
               )
    end

    test "rejects a slug with invalid characters", %{admin: admin} do
      assert {:error, %Ash.Error.Invalid{}} =
               Magus.Models.create_provider(
                 %{name: "Bad", slug: "Bad Slug!", req_llm_id: "openrouter"},
                 actor: admin
               )
    end

    test "rejects an over-long slug", %{admin: admin} do
      assert {:error, %Ash.Error.Invalid{}} =
               Magus.Models.create_provider(
                 %{name: "Long", slug: String.duplicate("a", 65), req_llm_id: "openrouter"},
                 actor: admin
               )
    end

    test "accepts the existing built-in slugs", %{admin: admin} do
      for slug <- ~w(openrouter openrouter_citations publicai xai fal aimlapi) do
        assert {:ok, _} =
                 Magus.Models.create_provider(
                   %{name: slug, slug: slug, req_llm_id: "openrouter"},
                   actor: admin
                 )
      end
    end

    test "get_provider_by_slug", %{admin: admin} do
      {:ok, provider} =
        Magus.Models.create_provider(%{name: "xAI", slug: "xai", req_llm_id: "xai"},
          actor: admin
        )

      assert {:ok, found} = Magus.Models.get_provider_by_slug("xai")
      assert found.id == provider.id
    end
  end

  describe "Provider delete lifecycle (FK guard)" do
    setup do
      %{admin: create_admin()}
    end

    test "destroying a provider with linked models is restricted, not orphaning", %{
      admin: admin
    } do
      {:ok, provider} =
        Magus.Models.create_provider(
          %{name: "Linked", slug: "linked_provider", req_llm_id: "openrouter"},
          actor: admin
        )

      model =
        Magus.Chat.Model
        |> Ash.Changeset.for_create(:create, %{
          name: "Linked Model",
          key: "linked_provider:foo/linked",
          provider: "Test",
          model_provider_id: provider.id
        })
        |> Ash.create!()

      # The FK on models.model_provider_id has no ON DELETE action, so deleting
      # a provider that still has models is blocked at the DB level and surfaces
      # as an error — never a silent cascade/nilify that orphans the model.
      # (The destroy action declares no `foreign_key_constraint`, so the
      # violation surfaces as an Ash.Error.Unknown wrapping Ecto.ConstraintError
      # rather than a validation error; either way the delete is refused.)
      assert {:error, error} = Magus.Models.destroy_provider(provider, actor: admin)
      assert is_exception(error)
      assert Exception.message(error) =~ "models_model_provider_id_fkey"

      # Provider and its model both still exist (no partial delete).
      assert {:ok, _} = Ash.get(Magus.Models.Provider, provider.id, actor: admin)

      reloaded = Ash.get!(Magus.Chat.Model, model.id, authorize?: false)
      assert reloaded.model_provider_id == provider.id
    end

    test "a provider with no linked models can be destroyed", %{admin: admin} do
      {:ok, provider} =
        Magus.Models.create_provider(
          %{name: "Lonely", slug: "lonely_provider", req_llm_id: "openrouter"},
          actor: admin
        )

      assert :ok = Magus.Models.destroy_provider(provider, actor: admin)
      assert {:error, _} = Ash.get(Magus.Models.Provider, provider.id, actor: admin)
    end
  end

  describe "Provider policies" do
    test "non-admin actor cannot create a provider" do
      user = create_actor()

      assert {:error, %Ash.Error.Forbidden{}} =
               Magus.Models.create_provider(
                 %{name: "X", slug: "x_test", req_llm_id: "openrouter"},
                 actor: user
               )
    end

    test "admin actor can create a provider" do
      admin = create_admin()

      assert {:ok, _} =
               Magus.Models.create_provider(
                 %{name: "Y", slug: "y_test", req_llm_id: "openrouter"},
                 actor: admin
               )
    end

    test "actorless read works (internal plumbing)" do
      assert {:ok, _} = Ash.read(Magus.Models.Provider)
    end
  end

  # Helper to create an admin user (same pattern as usage_plan_test.exs)
  defp create_admin do
    user = create_actor()

    {:ok, admin} =
      user
      |> Ash.Changeset.for_update(:update_profile, %{}, authorize?: false)
      |> Ash.Changeset.force_change_attribute(:is_admin, true)
      |> Ash.update(authorize?: false)

    admin
  end
end
