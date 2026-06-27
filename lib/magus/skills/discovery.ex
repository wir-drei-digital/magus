defmodule Magus.Skills.Discovery do
  @moduledoc """
  Per-actor skill discovery: merges built-in registry skills with the
  user/workspace skills an actor can access into one list of skill views,
  each carrying a stable `ref` that `load_skill` resolves unambiguously.

  Refs: built-in -> "builtin:<name>", user skill -> "user:<id>".
  """

  alias Magus.Agents.Skills.Registry

  @type view :: %{
          ref: String.t(),
          name: String.t(),
          description: String.t(),
          source: :builtin | :user,
          has_executable_bundle: boolean(),
          runnable: boolean()
        }

  @doc """
  List all skills visible to `actor` (built-in plus accessible user skills),
  as views with stable refs. Built-in views are always returned; user views
  require a non-nil `%Magus.Accounts.User{}` actor (access governed by policies).
  """
  @spec list_for_actor(struct() | nil) :: [view()]
  def list_for_actor(actor) do
    builtin_views() ++ user_views(actor)
  end

  defp builtin_views do
    Registry.list_skills()
    |> Enum.map(fn s ->
      %{
        ref: "builtin:" <> s.name,
        name: s.name,
        description: s.description || "",
        source: :builtin,
        has_executable_bundle: false,
        runnable: true
      }
    end)
  end

  defp user_views(nil), do: []

  defp user_views(actor) do
    case Magus.Skills.list_skills(actor: actor) do
      {:ok, skills} ->
        Enum.map(skills, fn s ->
          %{
            ref: "user:" <> s.id,
            name: s.name,
            description: s.description || "",
            source: :user,
            has_executable_bundle: s.has_executable_bundle,
            runnable: not s.has_executable_bundle or Magus.Sandbox.Provider.configured?()
          }
        end)

      _ ->
        []
    end
  end
end
