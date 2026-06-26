defmodule MagusWeb.PromptDetailLive do
  @moduledoc """
  LiveView for displaying prompt details.

  Shows comprehensive prompt information including content, tags, stats,
  additional information, similar prompts, and action buttons.
  """
  use MagusWeb, :live_view

  alias MagusWeb.Layouts

  import MagusWeb.ChatLive.Helpers, only: [to_markdown: 1]

  require Logger

  on_mount {MagusWeb.LiveUserAuth, :live_user_optional}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Magus.Library.get_prompt(id,
           authorize?: false,
           load: [:user, :tags, :model, favorite_count: []]
         ) do
      {:ok, prompt} ->
        socket =
          socket
          |> assign(:page_title, prompt.name)
          |> assign(:prompt, prompt)
          |> assign(:similar_prompts, [])
          |> load_user_favorites()
          |> load_similar_prompts(prompt)

        {:ok, socket}

      {:error, _} ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Prompt not found"))
         |> push_navigate(to: ~p"/prompts")}
    end
  end

  defp load_user_favorites(socket) do
    case socket.assigns.current_user do
      nil ->
        assign(socket, :is_favorited, false)

      user ->
        is_favorited =
          Magus.Library.my_prompt_favorites!(actor: user)
          |> Enum.any?(&(&1.prompt_id == socket.assigns.prompt.id))

        assign(socket, :is_favorited, is_favorited)
    end
  end

  defp load_similar_prompts(socket, prompt) do
    similar =
      try do
        Magus.Library.find_similar_prompts!(prompt.id,
          authorize?: false,
          load: [:user, :tags]
        )
      rescue
        e ->
          Logger.warning("Failed to load similar prompts: #{inspect(e)}")
          []
      end

    assign(socket, :similar_prompts, similar)
  end

  @impl true
  def render(assigns) do
    is_owner = assigns.current_user && assigns.prompt.user_id == assigns.current_user.id
    assigns = assign(assigns, :is_owner, is_owner)

    ~H"""
    <Layouts.content
      flash={@flash}
      current_user={@current_user}
      base_path={"/prompts/#{@prompt.id}"}
    >
      <div class="max-w-3xl mx-auto p-4 md:p-8">
        <%!-- Back Link --%>
        <.link
          navigate={~p"/prompts"}
          class="inline-flex items-center gap-1 text-sm text-base-content/60 hover:text-primary mb-6"
        >
          <.icon name="lucide-arrow-left" class="w-4 h-4" />
          {gettext("Back to Prompts")}
        </.link>

        <%!-- Content --%>
        <div>
          <%!-- Header Section --%>
          <div class="mb-6">
            <%!-- Title Row --%>
            <div class="flex items-start justify-between gap-4 mb-3">
              <h1 class="text-2xl md:text-3xl font-bold text-base-content">
                {@prompt.name}
              </h1>
              <button
                :if={@current_user}
                type="button"
                phx-click="favorite_prompt"
                class={"btn btn-circle btn-ghost #{if @is_favorited, do: "text-error"}"}
                title={if @is_favorited, do: gettext("Unlike"), else: gettext("Like")}
              >
                <.icon
                  name="lucide-heart"
                  class={"w-6 h-6 #{if @is_favorited, do: "fill-current"}"}
                />
              </button>
            </div>

            <%!-- Description --%>
            <p :if={@prompt.description} class="text-base-content/70 mb-4">
              {@prompt.description}
            </p>

            <%!-- Author Info with Prompt Information --%>
            <div class="flex flex-wrap items-center gap-x-4 gap-y-2 mb-4 text-sm">
              <div class="flex items-center gap-2">
                <.user_avatar user={@prompt.user} size="sm" />
                <span class="font-medium text-base-content">
                  {author_name(@prompt.user)}
                </span>
              </div>

              <span class="text-base-content/40">|</span>

              <span class="text-base-content/60">
                {gettext("Updated %{date}", date: format_date(@prompt.updated_at))}
              </span>

              <%= if @prompt.model do %>
                <span class="text-base-content/60">{@prompt.model.name}</span>
              <% end %>

              <span class="text-base-content/60">{language_label(@prompt.language)}</span>
            </div>

            <%!-- Tags --%>
            <div
              :if={(@prompt.tags && @prompt.tags != []) || @prompt.chat_mode}
              class="flex flex-wrap items-center gap-2 mb-4"
            >
              <%= if @prompt.type == :system && @prompt.chat_mode do %>
                <span class="type-tag type-tag-user">
                  {Phoenix.Naming.humanize(@prompt.chat_mode)}
                </span>
              <% end %>
              <%= for tag <- (@prompt.tags || []) do %>
                <span class="content-tag">#{tag.name}</span>
              <% end %>
            </div>

            <%!-- Stats Row --%>
            <div class="flex flex-wrap items-center gap-4 text-sm text-base-content/60 mb-4">
              <span class="flex items-center gap-1.5" title={gettext("Likes")}>
                <.icon name="lucide-heart" class="w-4 h-4" />
                {@prompt.favorite_count || 0}
              </span>
              <span class="flex items-center gap-1.5" title={gettext("Copies")}>
                <.icon name="lucide-files" class="w-4 h-4" />
                {@prompt.copy_count}
              </span>
              <span class="flex items-center gap-1.5" title={gettext("Uses")}>
                <.icon name="lucide-play" class="w-4 h-4" />
                {@prompt.use_count}
              </span>

              <%!-- Owner actions --%>
              <div :if={@is_owner} class="flex-1 flex justify-end gap-1">
                <button
                  phx-click="edit_prompt"
                  class="btn btn-xs btn-ghost"
                  title={gettext("Edit")}
                >
                  <.icon name="lucide-pencil" class="w-3.5 h-3.5" />
                </button>
                <button
                  phx-click="toggle_publish"
                  class="btn btn-xs btn-ghost"
                  title={if @prompt.is_public, do: gettext("Unpublish"), else: gettext("Publish")}
                >
                  <.icon
                    name={if @prompt.is_public, do: "lucide-eye-off", else: "lucide-eye"}
                    class="w-3.5 h-3.5"
                  />
                </button>
                <button
                  phx-click="delete_prompt"
                  data-confirm={gettext("Are you sure you want to delete this prompt?")}
                  class="btn btn-xs btn-ghost text-error"
                  title={gettext("Delete")}
                >
                  <.icon name="lucide-trash-2" class="w-3.5 h-3.5" />
                </button>
              </div>
            </div>

            <%!-- Actions Row --%>
            <div class="flex flex-wrap gap-2">
              <button
                type="button"
                phx-click="use_in_chat"
                class="btn btn-primary btn-sm gap-2"
              >
                <.icon name="lucide-play" class="w-4 h-4" />
                {gettext("Try in Chat")}
              </button>

              <button
                type="button"
                phx-click="copy_to_clipboard"
                id="copy-prompt-btn"
                phx-hook=".CopyToClipboard"
                data-content={@prompt.content}
                class="btn btn-outline btn-sm gap-2"
              >
                <.icon name="lucide-clipboard" class="w-4 h-4" />
                {gettext("Copy")}
              </button>

              <button
                type="button"
                phx-click="share_prompt"
                class="btn btn-outline btn-sm gap-2"
              >
                <.icon name="lucide-share-2" class="w-4 h-4" />
                {gettext("Share")}
              </button>

              <button
                :if={@current_user && !@is_owner}
                type="button"
                phx-click="fork_prompt"
                class="btn btn-outline btn-sm gap-2"
              >
                <.icon name="lucide-git-fork" class="w-4 h-4" />
                {gettext("Fork")}
              </button>
            </div>
          </div>

          <%!-- Prompt Content Card --%>
          <div class="bg-base-100 border border-base-300 rounded-xl shadow-sm mb-6">
            <%!-- System Prompt Section --%>
            <div class="p-5">
              <h2 class="text-sm font-semibold text-base-content/70 mb-3 flex items-center gap-2">
                <%= if @prompt.type == :system do %>
                  <.icon name="lucide-bot" class="w-4 h-4" />
                  {gettext("System Prompt")}
                <% else %>
                  <.icon name="lucide-user" class="w-4 h-4" />
                  {gettext("User Prompt")}
                <% end %>
              </h2>
              <div class="prose prose-sm max-w-none text-base-content">
                {to_markdown(@prompt.content)}
              </div>
            </div>
          </div>

          <%!-- Additional Information Section --%>
          <div
            :if={@prompt.additional_information && @prompt.additional_information != ""}
            class="bg-base-100 border border-base-300 rounded-xl p-5 shadow-sm mb-6"
          >
            <h2 class="text-lg font-semibold text-base-content mb-4 flex items-center gap-2">
              <.icon name="lucide-info" class="w-5 h-5 text-info" />
              {gettext("Additional Information")}
            </h2>
            <div class="prose prose-sm max-w-none text-base-content">
              {to_markdown(@prompt.additional_information)}
            </div>
          </div>

          <%!-- Similar Prompts Section --%>
          <div
            :if={@similar_prompts != []}
            class="bg-base-100 border border-base-300 rounded-xl p-5 shadow-sm mb-6"
          >
            <h2 class="text-lg font-semibold text-base-content mb-4 flex items-center gap-2">
              <.icon name="lucide-sparkles" class="w-5 h-5 text-primary" />
              {gettext("Similar Prompts")}
            </h2>
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
              <%= for similar <- @similar_prompts do %>
                <.link
                  navigate={~p"/prompts/#{similar.id}"}
                  class="block border border-base-300 rounded-lg p-4 hover:border-primary/50 hover:bg-base-200/30 transition-colors"
                >
                  <h3 class="font-medium text-base-content line-clamp-1">
                    {similar.name}
                  </h3>
                  <p class="text-sm text-base-content/60 mt-1">
                    {gettext("by %{author}", author: author_name(similar.user))}
                  </p>
                  <div class="flex items-center gap-3 mt-2 text-xs text-base-content/50">
                    <span class="flex items-center gap-1">
                      <.icon name="lucide-heart" class="w-3 h-3" />
                      {similar.copy_count}
                    </span>
                    <span class="flex items-center gap-1">
                      <.icon name="lucide-play" class="w-3 h-3" />
                      {similar.use_count}
                    </span>
                  </div>
                </.link>
              <% end %>
            </div>
          </div>
        </div>
      </div>
    </Layouts.content>

    <%!-- Copy to Clipboard Hook --%>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyToClipboard">
      export default {
        mounted() {
          this.el.addEventListener("click", () => {
            const content = this.el.dataset.content;
            navigator.clipboard.writeText(content).then(() => {
              this.pushEvent("clipboard_copied", {});
            }).catch(err => {
              console.error('Failed to copy:', err);
            });
          });
        }
      }
    </script>
    """
  end

  # ============================================
  # Helper Functions
  # ============================================

  defp author_name(nil), do: gettext("Unknown")

  defp author_name(user) do
    user.email |> to_string() |> String.split("@") |> List.first()
  end

  defp format_date(nil), do: ""

  defp format_date(datetime) do
    Calendar.strftime(datetime, "%b %d, %Y")
  end

  defp language_label(nil), do: "English"
  defp language_label(:en), do: "English"
  defp language_label(:de), do: "German"
  defp language_label(:es), do: "Spanish"
  defp language_label(:fr), do: "French"
  defp language_label(:zh), do: "Chinese"
  defp language_label(:ja), do: "Japanese"
  defp language_label(:ko), do: "Korean"
  defp language_label(:pt), do: "Portuguese"
  defp language_label(:ru), do: "Russian"
  defp language_label(:ar), do: "Arabic"
  defp language_label(other), do: to_string(other)

  # ============================================
  # Events
  # ============================================

  @impl true
  def handle_event("use_in_chat", _params, socket) do
    prompt = socket.assigns.prompt

    # Increment use count (fire and forget, no need to wait)
    Magus.Library.increment_prompt_use_count(prompt, authorize?: false)

    {:noreply, push_navigate(socket, to: ~p"/chat?use_prompt=#{prompt.id}")}
  end

  @impl true
  def handle_event("fork_prompt", _params, socket) do
    case socket.assigns.current_user do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Sign in to fork prompts"))}

      user ->
        prompt = socket.assigns.prompt

        {:ok, forked} =
          Magus.Library.copy_prompt_to_library!(
            prompt.id,
            %{
              name: prompt.name,
              content: prompt.content,
              type: prompt.type,
              metadata: prompt.metadata,
              variables: prompt.variables,
              model_id: prompt.model_id,
              chat_mode: prompt.chat_mode,
              description: prompt.description,
              user_message_template: prompt.user_message_template,
              additional_information: prompt.additional_information,
              language: prompt.language
            },
            actor: user
          )

        {:noreply,
         socket
         |> put_flash(:info, gettext("Prompt forked to your library"))
         |> push_navigate(to: ~p"/prompts/#{forked.id}/edit")}
    end
  end

  @impl true
  def handle_event("favorite_prompt", _params, socket) do
    case socket.assigns.current_user do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Sign in to like prompts"))}

      user ->
        prompt = socket.assigns.prompt

        case Magus.Library.my_prompt_favorites!(actor: user)
             |> Enum.find(&(&1.prompt_id == prompt.id)) do
          nil ->
            Magus.Library.create_prompt_favorite!(%{prompt_id: prompt.id}, actor: user)

            # Reload prompt with updated favorite_count
            {:ok, updated_prompt} =
              Magus.Library.get_prompt(prompt.id, authorize?: false, load: [favorite_count: []])

            {:noreply,
             socket
             |> assign(:prompt, %{prompt | favorite_count: updated_prompt.favorite_count})
             |> assign(:is_favorited, true)
             |> put_flash(:info, gettext("Added to likes"))}

          favorite ->
            Magus.Library.destroy_prompt_favorite!(favorite, actor: user)

            # Reload prompt with updated favorite_count
            {:ok, updated_prompt} =
              Magus.Library.get_prompt(prompt.id, authorize?: false, load: [favorite_count: []])

            {:noreply,
             socket
             |> assign(:prompt, %{prompt | favorite_count: updated_prompt.favorite_count})
             |> assign(:is_favorited, false)
             |> put_flash(:info, gettext("Removed from likes"))}
        end
    end
  end

  @impl true
  def handle_event("delete_prompt", _params, socket) do
    case socket.assigns.current_user do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Sign in to delete prompts"))}

      user ->
        prompt = socket.assigns.prompt

        if prompt.user_id == user.id do
          Magus.Library.destroy_prompt!(prompt, actor: user)

          {:noreply,
           socket
           |> put_flash(:info, gettext("Prompt deleted"))
           |> push_navigate(to: ~p"/prompts")}
        else
          {:noreply, put_flash(socket, :error, gettext("You can only delete your own prompts"))}
        end
    end
  end

  @impl true
  def handle_event("toggle_publish", _params, socket) do
    case socket.assigns.current_user do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Sign in to publish prompts"))}

      user ->
        prompt = socket.assigns.prompt

        if prompt.user_id == user.id do
          if prompt.is_public do
            {:ok, updated_prompt} = Magus.Library.unpublish_prompt(prompt, actor: user)

            {:noreply,
             socket
             |> assign(
               :prompt,
               Ash.load!(updated_prompt, [:user, :tags, :model, favorite_count: []])
             )
             |> put_flash(:info, gettext("Prompt unpublished"))}
          else
            {:ok, updated_prompt} =
              Magus.Library.publish_prompt(prompt, %{is_public: true}, actor: user)

            {:noreply,
             socket
             |> assign(
               :prompt,
               Ash.load!(updated_prompt, [:user, :tags, :model, favorite_count: []])
             )
             |> put_flash(:info, gettext("Prompt published"))}
          end
        else
          {:noreply, put_flash(socket, :error, gettext("You can only publish your own prompts"))}
        end
    end
  end

  @impl true
  def handle_event("edit_prompt", _params, socket) do
    {:noreply, push_navigate(socket, to: ~p"/prompts/#{socket.assigns.prompt.id}/edit")}
  end

  @impl true
  def handle_event("copy_to_clipboard", _params, socket) do
    # Handled by JS hook, this is a no-op
    {:noreply, socket}
  end

  @impl true
  def handle_event("clipboard_copied", _params, socket) do
    {:noreply, put_flash(socket, :info, gettext("Copied to clipboard"))}
  end

  @impl true
  def handle_event("share_prompt", _params, socket) do
    # The share URL will be copied via JS
    url = url(~p"/prompts/#{socket.assigns.prompt.id}")

    {:noreply,
     socket
     |> push_event("copy_to_clipboard", %{text: url})
     |> put_flash(:info, gettext("Share link copied to clipboard"))}
  end
end
