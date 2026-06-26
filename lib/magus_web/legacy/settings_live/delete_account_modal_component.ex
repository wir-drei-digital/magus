defmodule MagusWeb.SettingsLive.DeleteAccountModalComponent do
  @moduledoc """
  Confirmation modal for permanent account deletion.

  Renders one of two states based on the preflight result:
    * `{:error, :sole_admin_workspaces, workspaces}` — blocked state listing
      the workspaces the user must hand off or delete first.
    * `{:ok, summary}` — confirm state showing what will be deleted, and a
      form requiring the user to type their email before submission.

  The form posts to `/settings/data/delete` (the controller endpoint added
  in Task 12) so the response can clear the session and redirect.
  """
  use MagusWeb, :live_component

  @impl true
  def mount(socket) do
    {:ok, assign(socket, :typed_email, "")}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def handle_event("validate_confirm_email", %{"confirm_email" => typed}, socket) do
    {:noreply, assign(socket, :typed_email, typed)}
  end

  @impl true
  def render(assigns) do
    case assigns.preflight do
      {:error, :sole_admin_workspaces, workspaces} ->
        render_blocked(assign(assigns, :workspaces, workspaces))

      {:ok, summary} ->
        render_confirm(assign(assigns, :summary, summary))

      _ ->
        ~H"<div></div>"
    end
  end

  defp render_blocked(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-2xl">
        <h2 class="text-xl font-bold mb-4">{gettext("Can't delete your account yet")}</h2>
        <p class="mb-4">{gettext("You are the only admin of these workspaces:")}</p>
        <ul class="list-disc pl-6 mb-4 space-y-2">
          <li :for={ws <- @workspaces} class="flex items-center justify-between">
            <span>{ws.name}</span>
            <.link navigate={~p"/workspaces/#{ws.slug}"} class="link link-primary text-sm">
              {gettext("Open settings")}
            </.link>
          </li>
        </ul>
        <p class="text-sm text-base-content/70 mb-4">
          {gettext(
            "Transfer admin rights to another member or delete the workspaces, then come back here."
          )}
        </p>
        <div class="modal-action">
          <button type="button" phx-click="close_delete_account_modal" class="btn">
            {gettext("Close")}
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp render_confirm(assigns) do
    matches? =
      String.downcase(assigns.typed_email) ==
        String.downcase(to_string(assigns.current_user.email))

    assigns = assign(assigns, :matches?, matches?)

    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-2xl">
        <h2 class="text-xl font-bold mb-4">{gettext("Delete your account permanently")}</h2>

        <p class="mb-2">{gettext("This will immediately and permanently delete:")}</p>
        <ul class="list-disc pl-6 mb-4 text-sm space-y-1">
          <li>
            {ngettext(
              "%{count} conversation and all messages",
              "%{count} conversations and all messages",
              @summary.conversation_count,
              count: @summary.conversation_count
            )}
          </li>
          <li>
            {@summary.brain_count} {gettext("brains")}, {@summary.memory_count} {gettext("memories")}, {@summary.prompt_count} {gettext(
              "prompts"
            )}, {@summary.draft_count} {gettext("drafts")}
          </li>
          <li>{gettext("Your custom agents and their configuration")}</li>
          <li>{gettext("Your profile and preferences")}</li>
        </ul>

        <p :if={@summary.active_subscription} class="mb-4 text-sm bg-warning/10 p-3 rounded">
          {gettext(
            "Your active subscription will be cancelled immediately. You will not be refunded for the remaining period."
          )}
        </p>

        <p class="text-xs text-base-content/60 mb-6">
          {gettext(
            "Aggregated usage statistics (token counts, costs) are kept with your account reference removed, for billing reconciliation."
          )}
        </p>

        <form
          id="delete-account-form"
          phx-change="validate_confirm_email"
          phx-target={@myself}
          method="post"
          action={~p"/settings/data/delete"}
        >
          <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />

          <label class="block text-sm mb-2">
            {gettext("Type your email address to confirm:")}
          </label>
          <input
            type="text"
            name="confirm_email"
            value={@typed_email}
            class="input input-bordered w-full mb-4"
            autocomplete="off"
          />

          <div class="modal-action">
            <button type="button" phx-click="close_delete_account_modal" class="btn">
              {gettext("Cancel")}
            </button>
            <button type="submit" disabled={not @matches?} class="btn btn-error">
              {gettext("Delete my account")}
            </button>
          </div>
        </form>
      </div>
    </div>
    """
  end
end
