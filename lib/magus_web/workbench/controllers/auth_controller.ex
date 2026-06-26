defmodule MagusWeb.AuthController do
  use MagusWeb, :controller
  use AshAuthentication.Phoenix.Controller

  require Logger

  def success(conn, activity, user, _token) do
    invite_token = get_session(conn, :invite_token)
    return_to = get_session(conn, :return_to) || ~p"/chat"

    message =
      case activity do
        {:confirm_new_user, :confirm} -> gettext("Your email address has now been confirmed")
        {:password, :reset} -> gettext("Your password has successfully been reset")
        _ -> gettext("You are now signed in")
      end

    conn =
      conn
      |> delete_session(:return_to)
      |> delete_session(:invite_token)
      |> store_in_session(user)
      |> assign(:current_user, user)
      |> put_flash(:info, message)

    cond do
      invite_token != nil ->
        redirect(conn, to: ~p"/workspaces/invite/#{invite_token}")

      user.selected_plan_key not in [nil, "free"] ->
        redirect(conn, to: "/onboarding/checkout?plan=#{user.selected_plan_key}")

      true ->
        redirect(conn, to: return_to)
    end
  end

  def failure(conn, activity, reason) do
    Logger.warning("Auth failure for #{inspect(activity)}: #{inspect(reason)}")

    message =
      case {activity, reason} do
        {_,
         %AshAuthentication.Errors.AuthenticationFailed{
           caused_by: %Ash.Error.Forbidden{
             errors: [%AshAuthentication.Errors.CannotConfirmUnconfirmedUser{}]
           }
         }} ->
          gettext(
            "You have already signed in another way, but have not confirmed your account. " <>
              "You can confirm your account using the link we sent to you, or by resetting your password."
          )

        {{:confirm_new_user, :confirm}, _} ->
          gettext(
            "Unable to confirm your email. The link may have expired or already been used. " <>
              "Please request a new confirmation email."
          )

        {{:password, :reset}, _} ->
          gettext(
            "Unable to reset your password. The link may have expired or already been used. " <>
              "Please request a new password reset."
          )

        {{:magic_link, :sign_in}, _} ->
          gettext(
            "Unable to sign in with this magic link. The link may have expired or already been used. " <>
              "Please request a new magic link."
          )

        _ ->
          gettext("Incorrect email or password")
      end

    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/sign-in")
  end

  @impl AshAuthentication.Phoenix.Controller
  def sign_out(conn, _params) do
    return_to = get_session(conn, :return_to) || ~p"/"

    conn
    |> clear_session(:magus)
    |> put_flash(:info, "You are now signed out")
    |> redirect(to: return_to)
  end
end
