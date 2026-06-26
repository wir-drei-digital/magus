defmodule Magus.Workspaces.WorkspaceMember.Changes.SendInviteEmail do
  @moduledoc """
  After-action change that sends an invitation email to the invited member.
  """
  use Ash.Resource.Change

  require Logger

  import Swoosh.Email

  @from_email "support@magus.digital"
  @from_name "Magus"

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, member ->
      send_invite_email(member)
      {:ok, member}
    end)
  end

  defp send_invite_email(member) do
    invite_url = build_invite_url(member.invite_token)
    email = member.invite_email

    workspace =
      case Ash.load(member, :workspace, authorize?: false) do
        {:ok, m} -> m.workspace
        _ -> nil
      end

    workspace_name = if workspace, do: workspace.name, else: "a workspace"

    safe_workspace_name =
      workspace_name |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

    result =
      new()
      |> from({@from_name, @from_email})
      |> to({"", email})
      |> subject("You've been invited to #{workspace_name} on Magus")
      |> text_body("""
      Hi,

      You've been invited to join "#{workspace_name}" on Magus.

      Click the link below to accept the invitation:

      #{invite_url}

      This invitation expires in 7 days.

      If you don't have an account yet, you'll be able to create one after clicking the link.

      The Magus Team
      """)
      |> html_body("""
      <p>Hi,</p>
      <p>You've been invited to join <strong>#{safe_workspace_name}</strong> on Magus.</p>
      <p><a href="#{invite_url}" style="display:inline-block;padding:12px 24px;background:#6366f1;color:#fff;text-decoration:none;border-radius:8px;font-weight:bold;">Accept Invitation</a></p>
      <p>Or copy this link: #{invite_url}</p>
      <p style="color:#6b7280;font-size:14px;">This invitation expires in 7 days.</p>
      <p>If you don't have an account yet, you'll be able to create one after clicking the link.</p>
      <p>The Magus Team</p>
      """)
      |> Magus.Mailer.deliver()

    case result do
      {:ok, _} ->
        Logger.info("Workspace invite email sent to #{email}")

      {:error, reason} ->
        Logger.warning("Failed to send workspace invite email to #{email}: #{inspect(reason)}")
    end
  end

  defp build_invite_url(token) do
    Magus.Endpoint.url() <> "/workspaces/invite/#{token}"
  end
end
