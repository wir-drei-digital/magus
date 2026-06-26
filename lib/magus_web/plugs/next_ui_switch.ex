defmodule MagusWeb.Plugs.NextUiSwitch do
  @moduledoc """
  Serves the SvelteKit shell instead of LiveView for users who opted into the
  new UI — but only for routes in the `MagusWeb.NextUi` registry. Runs in the
  `:browser` pipeline after `load_from_session`; a no-op while the registry
  is empty.

  Only intercepts full-page GET loads. LiveView in-socket navigation bypasses
  plugs by design, which is fine: once a route is in the registry, opted-in
  users reach it from the SPA, not from LiveView navigation.
  """
  @behaviour Plug

  alias MagusWeb.NextUi

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "GET"} = conn, _opts) do
    if NextUi.enabled_for?(conn.assigns[:current_user]) and
         NextUi.migrated_route?(conn.request_path) do
      conn
      |> MagusWeb.NextUiController.spa(%{})
      |> Plug.Conn.halt()
    else
      conn
    end
  end

  def call(conn, _opts), do: conn
end
