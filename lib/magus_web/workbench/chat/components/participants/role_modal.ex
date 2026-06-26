defmodule MagusWeb.ChatLive.Components.Participants.RoleModal do
  @moduledoc """
  Modal component for changing a participant's role.
  """
  use Phoenix.Component
  use Gettext, backend: MagusWeb.Gettext

  attr :show, :boolean, required: true
  attr :editing_member_id, :string, default: nil
  attr :myself, :any, required: true

  def role_modal(assigns) do
    ~H"""
    <dialog id="role-modal" class={"modal #{if @show, do: "modal-open"}"}>
      <div class="modal-box max-w-sm">
        <h3 class="font-bold text-lg mb-4">{gettext("Change Role")}</h3>
        <.form for={%{}} phx-submit="change_role" phx-target={@myself}>
          <input type="hidden" name="member_id" value={@editing_member_id} />
          <div class="form-control mb-4">
            <label class="label">
              <span class="label-text">{gettext("New role")}</span>
            </label>
            <select name="role" class="select select-bordered">
              <option value="member">{gettext("Member")}</option>
              <option value="observer">{gettext("Observer (read-only)")}</option>
            </select>
          </div>
          <div class="modal-action">
            <button
              type="button"
              class="btn"
              phx-click="hide_role_modal"
              phx-target={@myself}
            >
              {gettext("Cancel")}
            </button>
            <button type="submit" class="btn btn-primary">
              {gettext("Update Role")}
            </button>
          </div>
        </.form>
      </div>
      <div class="modal-backdrop" phx-click="hide_role_modal" phx-target={@myself}></div>
    </dialog>
    """
  end
end
