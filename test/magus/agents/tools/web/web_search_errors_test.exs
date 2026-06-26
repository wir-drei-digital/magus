defmodule Magus.Agents.Tools.Web.WebSearchErrorsTest do
  @moduledoc """
  WebSearch surfaces provider-agnostic error text: no `EXA_API_KEY` / "Exa.ai"
  leaks and a readable message when no search provider is configured.
  """
  # async: false — mutates the global :magus, :search_provider app env.
  use ExUnit.Case, async: false

  alias Magus.Agents.Tools.Web.WebSearch

  defmodule NotConfiguredProvider do
    @behaviour Magus.Capabilities.Search.Provider
    @impl true
    def configured?, do: false
    @impl true
    def search(_query, _opts), do: {:error, :not_configured}
  end

  setup do
    original = Application.get_env(:magus, :search_provider)
    Application.put_env(:magus, :search_provider, NotConfiguredProvider)

    on_exit(fn ->
      if original,
        do: Application.put_env(:magus, :search_provider, original),
        else: Application.delete_env(:magus, :search_provider)
    end)

    :ok
  end

  test "an unconfigured search returns a provider-agnostic 'not configured' error" do
    assert {:ok, result} = WebSearch.run(%{query: "anything"}, %{})

    assert result.results == []
    assert result.query == "anything"
    assert result.error =~ "not configured"
    refute result.error =~ "EXA"
    refute result.error =~ "Exa"
  end
end
