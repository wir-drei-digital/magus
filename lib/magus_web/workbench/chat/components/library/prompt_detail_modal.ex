defmodule MagusWeb.ChatLive.Components.Library.PromptDetailModal do
  @moduledoc """
  Modal component for viewing prompt details.

  Shows prompt metadata, content preview, and action buttons for
  activating system prompts or inserting user prompts.
  """
  use Phoenix.Component
  use Gettext, backend: MagusWeb.Gettext

  import MagusWeb.CoreComponents
  import MagusWeb.Live.Shared.ComponentUtils, only: [prompt_type_label: 1]
  import MagusWeb.ChatLive.Helpers, only: [to_markdown: 1]

  attr :prompt, :map, required: true
  attr :myself, :any, default: nil
  attr :active, :boolean, default: false

  def prompt_detail_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-2xl">
        <%!-- Header --%>
        <div class="flex items-start justify-between gap-4 mb-4">
          <div class="flex-1">
            <div class="flex items-center gap-2 mb-2">
              <span class={"type-tag #{type_tag_class(@prompt.type)}"}>
                {prompt_type_label(@prompt.type)}
              </span>
              <%= if @prompt.type == :system && @prompt.chat_mode do %>
                <span class="type-tag type-tag-user">
                  {Phoenix.Naming.humanize(@prompt.chat_mode)}
                </span>
              <% end %>
              <%= if @prompt.is_public do %>
                <span title={gettext("Public")}>
                  <.icon name="lucide-globe" class="w-4 h-4 text-success" />
                </span>
              <% else %>
                <span title={gettext("Private")}>
                  <.icon name="lucide-lock" class="w-4 h-4 text-base-content/40" />
                </span>
              <% end %>
            </div>
            <h3 class="text-xl font-bold text-base-content">{@prompt.name}</h3>
            <%= if @prompt.type == :system && @prompt.model do %>
              <p class="text-sm text-base-content/60 mt-1 flex items-center gap-1">
                <.icon name="lucide-cpu" class="w-4 h-4" />
                {@prompt.model.name}
              </p>
            <% end %>
          </div>
          <button
            type="button"
            class="btn btn-sm btn-circle btn-ghost"
            phx-click="close_prompt_detail"
            phx-target={@myself}
          >
            <.icon name="lucide-x" class="w-5 h-5" />
          </button>
        </div>

        <%!-- Content --%>
        <div class="bg-base-200 rounded-lg p-4 mb-6 max-h-96 overflow-y-auto">
          <h4 class="text-sm font-semibold text-base-content/70 mb-2">{gettext("Prompt Content")}</h4>
          <div class="prose prose-sm max-w-none text-base-content">
            {to_markdown(@prompt.content)}
          </div>
        </div>

        <%!-- Actions --%>
        <div class="modal-action">
          <%= if @prompt.type == :system do %>
            <%= if @active do %>
              <button
                type="button"
                phx-click="deactivate_system_prompt"
                phx-target={@myself}
                class="btn btn-warning"
              >
                <.icon name="lucide-pause" class="w-5 h-5" /> {gettext("Deactivate")}
              </button>
            <% else %>
              <button
                type="button"
                phx-click="activate_and_close"
                phx-value-id={@prompt.id}
                phx-target={@myself}
                class="btn btn-primary"
              >
                <.icon name="lucide-play" class="w-5 h-5" /> {gettext("Activate")}
              </button>
            <% end %>
          <% else %>
            <button
              type="button"
              phx-click="insert_and_close"
              phx-value-id={@prompt.id}
              phx-target={@myself}
              class="btn btn-primary"
            >
              <.icon name="lucide-play" class="w-5 h-5" /> {gettext("Insert into Chat")}
            </button>
          <% end %>
          <button
            type="button"
            phx-click="edit_prompt"
            phx-value-id={@prompt.id}
            phx-target={@myself}
            class="btn btn-ghost"
          >
            <.icon name="lucide-pencil" class="w-5 h-5" /> {gettext("Edit")}
          </button>
        </div>
      </div>
      <div class="modal-backdrop bg-black/50" phx-click="close_prompt_detail" phx-target={@myself}>
      </div>
    </div>
    """
  end

  defp type_tag_class(:system), do: "type-tag-system"
  defp type_tag_class(:user), do: "type-tag-user"
end
