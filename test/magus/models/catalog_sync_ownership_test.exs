defmodule Magus.Models.CatalogSyncOwnershipTest do
  use Magus.DataCase, async: false

  import Magus.Generators

  alias Magus.Models.CatalogSync

  setup do
    Magus.DataCase.clear_catalog!()
    user = generate(user())

    {:ok, provider} =
      Magus.Models.create_owned_provider(
        %{name: "Mine", req_llm_id: "openai", api_key: "sk"},
        actor: user
      )

    {:ok, _model} =
      Magus.Chat.create_owned_model(
        %{name: "M", model_id: "gpt-x", model_provider_id: provider.id},
        actor: user
      )

    %{provider: provider}
  end

  test "owned providers are excluded from the custom catalog map", %{provider: provider} do
    custom = CatalogSync.build_custom()
    slug_atom = String.to_atom(provider.slug)
    refute Map.has_key?(custom, slug_atom)
  end
end
