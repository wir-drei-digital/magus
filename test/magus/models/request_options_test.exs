defmodule Magus.Models.RequestOptionsTest do
  use Magus.DataCase, async: false

  alias Magus.Models.RequestOptions

  setup do
    # Clear seeded catalog rows (and their referencing rows) so these tests
    # create their own providers/models inline. Rolled back after the test.
    Magus.DataCase.clear_catalog!()
    :ok
  end

  test "returns api_key when the model's provider has a stored key" do
    {:ok, provider} =
      Magus.Models.create_provider(
        %{
          name: "OpenRouter",
          slug: "openrouter",
          req_llm_id: "openrouter",
          api_key: "sk-from-db"
        },
        authorize?: false
      )

    Magus.Chat.Model
    |> Ash.Changeset.for_create(:create, %{
      name: "M",
      key: "openrouter:foo/m",
      provider: "Test",
      context_window: 1_000,
      model_provider_id: provider.id
    })
    |> Ash.create!(authorize?: false)

    assert {"openrouter:foo/m", [api_key: "sk-from-db"]} =
             RequestOptions.resolve("openrouter:foo/m")
  end

  test "custom openai_compatible provider yields inline model + base_url" do
    {:ok, provider} =
      Magus.Models.create_provider(
        %{
          name: "Local",
          slug: "local_vllm",
          req_llm_id: "openai_compatible",
          base_url: "http://localhost:8000/v1",
          api_key: "sk-local"
        },
        authorize?: false
      )

    Magus.Chat.Model
    |> Ash.Changeset.for_create(:create, %{
      name: "Llama",
      key: "local_vllm:llama-3",
      provider: "Meta",
      context_window: 8_000,
      model_provider_id: provider.id
    })
    |> Ash.create!(authorize?: false)

    assert {%{provider: :openai_compatible, id: "llama-3"}, opts} =
             RequestOptions.resolve("local_vllm:llama-3")

    assert opts[:base_url] == "http://localhost:8000/v1"
    assert opts[:api_key] == "sk-local"
  end

  test "built-in provider model resolves to its spec string unchanged" do
    assert {"openrouter:not/in-db", []} = RequestOptions.resolve("openrouter:not/in-db")
  end

  test "disabled provider is ignored (env fallback)" do
    {:ok, provider} =
      Magus.Models.create_provider(
        %{
          name: "Off",
          slug: "off_provider",
          req_llm_id: "openrouter",
          api_key: "sk-unused",
          enabled?: false
        },
        authorize?: false
      )

    Magus.Chat.Model
    |> Ash.Changeset.for_create(:create, %{
      name: "OffModel",
      key: "off_provider:foo",
      provider: "Test",
      context_window: 1_000,
      model_provider_id: provider.id
    })
    |> Ash.create!(authorize?: false)

    assert {"off_provider:foo", []} = RequestOptions.resolve("off_provider:foo")
  end
end
