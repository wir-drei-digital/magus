defmodule MagusWeb.NextUi do
  @moduledoc """
  Migrated-route registry and toggle helpers for the SvelteKit workbench.

  Gradual rollout works on two independent dimensions (migration spec §5):

    * **Who** — `User.ui_preferences["workbench_ui"]` (`"classic"` default,
      `"next"` opts into the SPA), written via the existing
      `update_ui_preferences` action.
    * **Which routes** — `@migrated_route_prefixes` lists the workbench routes
      the SPA currently supports. It grows as panes reach parity (e.g.
      `"/chat"` after iteration 3). Routes not listed here always serve
      LiveView, even for opted-in users, so a half-migrated app is never
      broken for anyone.

  The SPA itself is always reachable at `/next` for preview/dogfooding,
  independent of the toggle.
  """

  @workbench_ui_key "workbench_ui"

  # Route prefixes served by the SPA for opted-in users. Intentionally empty
  # in iteration 0; grows per-pane as parity checklists pass.
  @migrated_route_prefixes []

  @doc "True if `path` is served by the SvelteKit app for opted-in users."
  def migrated_route?(path) when is_binary(path) do
    Enum.any?(@migrated_route_prefixes, fn prefix ->
      path == prefix or String.starts_with?(path, prefix <> "/")
    end)
  end

  @doc "True if the user has opted into the new UI."
  def enabled_for?(nil), do: false

  def enabled_for?(user) do
    (user.ui_preferences || %{})[@workbench_ui_key] == "next"
  end
end
