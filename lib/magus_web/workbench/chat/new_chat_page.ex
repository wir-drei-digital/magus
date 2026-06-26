defmodule MagusWeb.ChatLive.NewChatPage do
  @moduledoc """
  Component for the new chat page that shows feature discovery cards
  based on the user's onboarding state.

  Three views:
  1. First-time user: Welcome heading + all 4 feature cards in 2x2 grid
  2. Returning user: "New Conversation" heading + announcements + remaining feature cards
  3. Fully onboarded: "New Conversation" heading + announcements only
  """
  use Phoenix.Component

  use Gettext, backend: MagusWeb.Gettext

  import MagusWeb.ChatLive.Components.Tasks.DueDateHelpers

  alias MagusWeb.Components.ActionCards

  defp onboarding_card(feature_key, %{icon: icon, title: title, description: description}) do
    locale = Gettext.get_locale(MagusWeb.Gettext)

    %{
      "icon" => icon,
      "title" => title[locale] || title["en"],
      "description" => description[locale] || description["en"],
      "action" => %{
        "type" => "navigate",
        "payload" => "/chat?skill=onboarding&topic=#{feature_key}"
      }
    }
  end

  attr :undiscovered_features, :list, default: []
  attr :first_time?, :boolean, default: false
  attr :announcements, :list, default: []
  attr :user_open_tasks, :list, default: []

  def new_chat_page(assigns) do
    cards = cards_for_features(assigns.undiscovered_features)

    assigns =
      assigns
      |> assign(:cards, cards)
      |> assign(:action_cards_data, if(cards != [], do: %{"layout" => "grid", "cards" => cards}))

    ~H"""
    <div class="flex flex-col items-center justify-center min-h-[60vh]">
      <div class="max-w-lg w-full">
        <div class="flex justify-center mb-4">
          <span
            id="magus-logo"
            phx-hook=".MagusLogo"
            phx-update="ignore"
            class="magus-logo-animated text-primary text-6xl leading-none cursor-default select-none"
          >
            ◬
          </span>
        </div>
        <script :type={Phoenix.LiveView.ColocatedHook} name=".MagusLogo">
          export default {
            mounted() {
              this.el.addEventListener("mouseenter", () => {
                if (!this.el.classList.contains("is-spinning")) {
                  this.el.classList.add("is-spinning");
                }
              });
              this.el.addEventListener("animationend", (e) => {
                if (e.animationName === "magus-spin") {
                  this.el.classList.remove("is-spinning");
                }
              });
            }
          }
        </script>
        <%= if @first_time? do %>
          <div class="text-center mb-6">
            <p class="text-base-content text-lg font-logo mt-2">
              {gettext("What would you like to explore?")}
            </p>
          </div>
        <% else %>
          <div class="text-center mb-6">
            <p class="text-base-content text-lg font-logo mt-1">
              {gettext("What's on your mind?")}
            </p>
          </div>
        <% end %>

        <.announcements_section announcements={@announcements} />

        <div :if={@user_open_tasks != []} class="w-full max-w-2xl mx-auto mt-6">
          <h3 class="text-sm font-medium text-base-content/60 mb-2">
            {gettext("Your open tasks")}
          </h3>
          <div class="space-y-1">
            <div
              :for={task <- @user_open_tasks}
              id={"open-task-#{task.id}"}
              class="flex items-center justify-between gap-2 p-2 rounded-lg hover:bg-base-200 transition-colors group"
            >
              <button
                type="button"
                phx-click="complete_open_task"
                phx-value-id={task.id}
                class="shrink-0 w-4 h-4 rounded-full border border-base-content/30 hover:border-success hover:bg-success/20"
                aria-label={gettext("Mark done")}
              />
              <.link
                navigate={"/chat/#{task.conversation_id}"}
                class="flex-1 min-w-0 flex items-center justify-between"
              >
                <span class="text-sm truncate">{task.title}</span>
                <span
                  :if={task.due_at}
                  class={[
                    "text-xs shrink-0 ml-2",
                    overdue?(task.due_at) && "text-error",
                    !overdue?(task.due_at) && "text-base-content/50"
                  ]}
                >
                  {format_due_date(task.due_at)}
                </span>
              </.link>
              <button
                type="button"
                phx-click="dismiss_open_task"
                phx-value-id={task.id}
                class="shrink-0 btn btn-ghost btn-xs btn-circle opacity-0 group-hover:opacity-100"
                aria-label={gettext("Dismiss")}
              >
                ✕
              </button>
            </div>
          </div>
        </div>

        <%= if @undiscovered_features != [] do %>
          <div class={unless @first_time?, do: "mt-6"}>
            <h2 :if={not @first_time?} class="text-sm font-medium text-base-content/50 mb-3">
              {gettext("Try it out")}
            </h2>
            <ActionCards.action_cards action_cards={@action_cards_data} />
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  attr :announcements, :list, required: true

  defp announcements_section(assigns) do
    locale = Gettext.get_locale(MagusWeb.Gettext)
    assigns = assign(assigns, :locale, locale)

    ~H"""
    <div :for={announcement <- @announcements} class="mb-4">
      <div class="card card-border bg-base-200">
        <div class="card-body p-4">
          <div class="flex items-start justify-between gap-3">
            <div class="flex items-start gap-3">
              <span
                :if={announcement.icon && announcement.icon != ""}
                class={[
                  "flex-shrink-0",
                  if(String.starts_with?(announcement.icon, "lucide-"),
                    do: "#{announcement.icon} w-5 h-5 text-primary mt-0.5",
                    else: "text-xl"
                  )
                ]}
                aria-hidden="true"
              >
                {unless String.starts_with?(announcement.icon, "lucide-"), do: announcement.icon}
              </span>
              <div>
                <div class="flex items-center gap-2">
                  <span class="badge badge-primary badge-sm">{gettext("NEW")}</span>
                  <span class="font-semibold text-sm text-base-content">
                    {localized(announcement.title, @locale)}
                  </span>
                </div>
                <p :if={announcement.description} class="text-xs text-base-content/60 mt-1">
                  {localized(announcement.description, @locale)}
                </p>
                <.link
                  :if={announcement.action_payload}
                  navigate={announcement.action_payload}
                  class="text-xs text-primary hover:underline mt-1 inline-block"
                >
                  {gettext("Learn more")}
                </.link>
              </div>
            </div>
            <button
              type="button"
              phx-click="dismiss_announcement"
              phx-value-key={announcement.key}
              class="btn btn-ghost btn-xs btn-circle flex-shrink-0"
            >
              ✕
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp localized(translations, locale) when is_map(translations) do
    translations[locale] || translations["en"] || ""
  end

  defp localized(value, _locale), do: value || ""

  defp cards_for_features(features) do
    registry = Magus.FeatureUsage.onboarding_features()

    features
    |> Enum.map(fn key ->
      case Map.get(registry, key) do
        nil -> nil
        meta -> onboarding_card(key, meta)
      end
    end)
    |> Enum.reject(&is_nil/1)
  end
end
