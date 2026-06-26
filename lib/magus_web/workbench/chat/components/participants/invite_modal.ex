defmodule MagusWeb.ChatLive.Components.Participants.InviteModal do
  @moduledoc """
  Modal component for inviting participants to a conversation.

  Supports:
  - Toggle between invite_only and public visibility
  - Email invitations with role selection
  - Public invite links with optional password protection
  """
  use Phoenix.Component
  use Gettext, backend: MagusWeb.Gettext

  import MagusWeb.ChatLive.Components.Participants.UIHelpers, only: [invite_link_item: 1]
  import MagusWeb.CoreComponents, only: [input: 1]

  attr :show, :boolean, required: true
  attr :visibility, :atom, required: true
  attr :invite_links, :list, default: []
  attr :show_password_input, :boolean, default: false
  attr :myself, :any, required: true

  def invite_modal(assigns) do
    ~H"""
    <dialog id="invite-modal" class={"modal #{if @show, do: "modal-open"}"}>
      <div class="modal-box max-w-md">
        <h3 class="font-bold text-lg mb-4">{gettext("Invite Participants")}</h3>

        <%!-- Visibility Toggle (Owner only) --%>
        <div class="form-control mb-4">
          <label class="label cursor-pointer justify-start gap-3">
            <span class="label-text">{gettext("Allow anyone with link to join")}</span>
            <input
              type="checkbox"
              class="toggle toggle-primary toggle-sm"
              checked={@visibility == :public}
              phx-click="toggle_visibility"
              phx-target={@myself}
            />
          </label>
          <p class="text-xs text-base-content/60 ml-0">
            <%= if @visibility == :public do %>
              {gettext("Anyone with the public link can join this conversation.")}
            <% else %>
              {gettext("Only people you invite by email can join.")}
            <% end %>
          </p>
        </div>

        <div class="divider my-2"></div>

        <%!-- Email Invite Section --%>
        <div class="mb-4">
          <h4 class="font-medium text-sm mb-2">{gettext("Invite by Email")}</h4>
          <.form for={%{}} phx-submit="invite_by_email" phx-target={@myself}>
            <div class="form-control mb-3">
              <input
                type="email"
                name="email"
                class="input input-bordered input-sm"
                placeholder="user@example.com"
                required
              />
            </div>
            <div class="flex gap-2">
              <select name="role" class="select select-bordered select-sm flex-1">
                <option value="member">{gettext("Member")}</option>
                <option value="observer">{gettext("Observer (read-only)")}</option>
              </select>
              <button type="submit" class="btn btn-primary btn-sm">
                {gettext("Send Invite")}
              </button>
            </div>
          </.form>
        </div>

        <%!-- Public Link Section (only if visibility is public) --%>
        <div :if={@visibility == :public}>
          <div class="divider my-2"></div>
          <h4 class="font-medium text-sm mb-2">{gettext("Public Link")}</h4>

          <div :if={@invite_links == []}>
            <p class="text-sm text-base-content/70 mb-3">
              {gettext("Create a link that anyone can use to join.")}
            </p>
            <.form for={%{}} phx-submit="create_invite_link" phx-target={@myself}>
              <div class="flex gap-2 mb-3">
                <select name="role" class="select select-bordered select-sm flex-1">
                  <option value="member">{gettext("Join as Member")}</option>
                  <option value="observer">{gettext("Join as Observer (read-only)")}</option>
                </select>
              </div>
              <.input
                type="checkbox"
                name="has_password"
                id="has_password"
                label={gettext("Password protect")}
                checked={@show_password_input}
                phx-click="toggle_password"
                phx-target={@myself}
              />
              <div :if={@show_password_input} class="form-control mb-3">
                <input
                  type="password"
                  name="password"
                  class="input input-bordered input-sm"
                  placeholder={gettext("Enter password")}
                />
              </div>
              <button type="submit" class="btn btn-outline btn-sm w-full">
                {gettext("Create Link")}
              </button>
            </.form>
          </div>

          <div :if={@invite_links != []}>
            <div class="space-y-2">
              <.invite_link_item :for={link <- @invite_links} link={link} myself={@myself} />
            </div>
            <button
              class="btn btn-ghost btn-xs w-full mt-2"
              phx-click="reset_links"
              phx-target={@myself}
            >
              {gettext("+ Create another link")}
            </button>
          </div>
        </div>

        <div class="modal-action">
          <button class="btn btn-sm" phx-click="hide_invite_modal" phx-target={@myself}>
            {gettext("Close")}
          </button>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="hide_invite_modal" phx-target={@myself}></div>
    </dialog>
    """
  end
end
