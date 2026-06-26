defmodule MagusWeb.SettingsController do
  use MagusWeb, :controller

  import AshAuthentication.Phoenix.Controller, only: [clear_session: 2]

  def export_data(conn, _params) do
    user = conn.assigns.current_user
    data = Magus.Accounts.DataExport.build(user)
    filename = "magus-export-#{Date.utc_today()}.json"

    conn
    |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(data, pretty: true))
  end

  def delete_account(conn, %{"confirm_email" => typed}) do
    user = conn.assigns.current_user

    if String.downcase(typed) != String.downcase(to_string(user.email)) do
      conn
      |> put_flash(:error, gettext("Email did not match. Account was not deleted."))
      |> redirect(to: ~p"/settings/data")
    else
      case Magus.Accounts.AccountDeletion.execute(user) do
        :ok ->
          conn
          |> clear_session(:magus)
          |> put_flash(:info, gettext("Your account has been deleted."))
          |> redirect(to: ~p"/")

        {:error, :lifecycle_aborted} ->
          conn
          |> put_flash(
            :error,
            gettext("We could not cancel your subscription. Please try again or contact support.")
          )
          |> redirect(to: ~p"/settings/data")

        {:error, :sole_admin_workspaces, _} ->
          conn
          |> put_flash(
            :error,
            gettext(
              "You are still the only admin of one or more workspaces. Transfer admin rights or delete the workspaces first."
            )
          )
          |> redirect(to: ~p"/settings/data")

        {:error, _other} ->
          conn
          |> put_flash(:error, gettext("Could not delete account. Please contact support."))
          |> redirect(to: ~p"/settings/data")
      end
    end
  end

  def delete_account(conn, _params) do
    conn
    |> put_flash(:error, gettext("Email confirmation required."))
    |> redirect(to: ~p"/settings/data")
  end

  def confirm_email_change(conn, %{"token" => token}) do
    # First verify the token to get user_id
    case Phoenix.Token.verify(MagusWeb.Endpoint, "email_change", token, max_age: 86400) do
      {:ok, {user_id, _new_email}} ->
        # Get the user and confirm the email change
        case Magus.Accounts.get_user(user_id, authorize?: false) do
          {:ok, user} ->
            case Magus.Accounts.confirm_email_change(user, token, actor: user) do
              {:ok, _user} ->
                conn
                |> put_flash(:info, "Email address changed successfully!")
                |> redirect(to: ~p"/settings")

              {:error, _changeset} ->
                conn
                |> put_flash(:error, "Invalid or expired confirmation link.")
                |> redirect(to: ~p"/settings")
            end

          {:error, _} ->
            conn
            |> put_flash(:error, "Invalid or expired confirmation link.")
            |> redirect(to: ~p"/sign-in")
        end

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Invalid or expired confirmation link.")
        |> redirect(to: ~p"/sign-in")
    end
  end
end
