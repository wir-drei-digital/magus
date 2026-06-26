defmodule MagusWeb.Hooks.SetLiveLocale do
  @moduledoc """
  LiveView on_mount hook that reads the `:locale` URL param,
  validates it, sets Gettext locale, and assigns `@locale`.
  """
  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 3]

  @default_locale MagusWeb.Plugs.SetLocale.default_locale()

  def on_mount(:set_locale, %{"locale" => locale}, _session, socket)
      when locale in ~w(en de) do
    Gettext.put_locale(MagusWeb.Gettext, locale)
    {:cont, assign(socket, :locale, locale)}
  end

  def on_mount(:set_locale, %{"locale" => _invalid}, _session, socket) do
    # Invalid locale — redirect to default
    {:halt, redirect(socket, to: "/#{@default_locale}/")}
  end

  def on_mount(:set_locale, _params, _session, socket) do
    # No locale param — shouldn't happen if routes are set up correctly
    Gettext.put_locale(MagusWeb.Gettext, @default_locale)
    {:cont, assign(socket, :locale, @default_locale)}
  end
end
