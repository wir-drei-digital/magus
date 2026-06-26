defmodule MagusWeb.LiveUserAuth do
  @moduledoc """
  Helpers for authenticating users in LiveViews.
  """

  import Phoenix.Component
  use MagusWeb, :verified_routes

  @supported_locales ~w(en de)
  @default_locale "en"

  # This is used for nested liveviews to fetch the current user.
  # To use, place the following at the top of that liveview:
  # on_mount {MagusWeb.LiveUserAuth, :current_user}
  def on_mount(:current_user, _params, session, socket) do
    socket = AshAuthentication.Phoenix.LiveSession.assign_new_resources(socket, session)
    set_locale(socket.assigns[:current_user], session)
    {:cont, socket}
  end

  def on_mount(:live_user_optional, _params, session, socket) do
    set_locale(socket.assigns[:current_user], session)

    if socket.assigns[:current_user] do
      {:cont, socket}
    else
      {:cont, assign(socket, :current_user, nil)}
    end
  end

  def on_mount(:live_user_required, _params, session, socket) do
    set_locale(socket.assigns[:current_user], session)

    case socket.assigns[:current_user] do
      nil ->
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/sign-in")}

      %{accepted_terms: false} ->
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/complete-profile")}

      _user ->
        {:cont, socket}
    end
  end

  # Same as :live_user_required but without profile completion check.
  # Used by the /complete-profile page itself to avoid infinite redirects.
  def on_mount(:live_user_required_no_profile_check, _params, session, socket) do
    set_locale(socket.assigns[:current_user], session)

    if socket.assigns[:current_user] do
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/sign-in")}
    end
  end

  def on_mount(:live_no_user, _params, session, socket) do
    set_locale(nil, session)

    if socket.assigns[:current_user] do
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/")}
    else
      {:cont, assign(socket, :current_user, nil)}
    end
  end

  def on_mount(:live_admin_required, _params, session, socket) do
    user = socket.assigns[:current_user]
    set_locale(user, session)

    cond do
      is_nil(user) ->
        {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/sign-in")}

      user.is_admin == true ->
        {:cont, socket}

      true ->
        {:halt,
         socket
         |> Phoenix.LiveView.put_flash(:error, "You don't have access to this area.")
         |> Phoenix.LiveView.redirect(to: ~p"/")}
    end
  end

  # Restores the Gettext locale for child `live_render` LiveViews. They mount in
  # their own process and would otherwise fall back to the default locale on
  # connect; the parent's resolved locale is propagated via the session by
  # MagusWeb.Workbench.Live.DetailView.
  def on_mount(:restore_locale, _params, session, socket) do
    case session do
      %{"locale" => locale} when is_binary(locale) ->
        Gettext.put_locale(MagusWeb.Gettext, locale)

      _ ->
        :ok
    end

    {:cont, socket}
  end

  defp set_locale(user, session) do
    locale =
      case user do
        %{language: language} when not is_nil(language) ->
          lang = to_string(language)
          if lang in @supported_locales, do: lang, else: nil

        _ ->
          nil
      end

    locale = locale || session["locale"] || @default_locale
    Gettext.put_locale(MagusWeb.Gettext, locale)
  end
end
