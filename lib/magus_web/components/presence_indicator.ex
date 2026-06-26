defmodule MagusWeb.Components.PresenceIndicator do
  @moduledoc """
  Renders the set of users currently viewing a resource.

  Two density variants share the same data:

    * `:avatars` — 32px circles, ideal for roomy headers (conversation, draft).
      Renders the user's `avatar_path` image when present, otherwise the
      initial-circle fallback with the user's deterministic color.

    * `:dots` — 24px initial circles, ideal for tight headers (brain page in
      a side pane, spreadsheet toolbar).

  Both filter the current user out, drop hidden viewers, cap at `max`, and
  show a `+N` overflow pill past the cap. Hover renders a real DOM `<title>`
  so screen readers and tooltips both work.

  A colocated phx-hook on the wrapper turns the browser's `visibilitychange`
  event into LiveView `presence:visible` / `presence:hidden` events carrying
  the indicator's topic.
  """
  use Phoenix.Component

  attr :viewers, :list,
    required: true,
    doc: "list of viewer maps: %{user_id, name, avatar_path, color, visible?}"

  attr :current_user_id, :string, required: true
  attr :variant, :atom, default: :avatars, values: [:avatars, :dots]

  attr :max, :integer,
    default: nil,
    doc: "overflow cap; defaults to 5 for :avatars, 3 for :dots"

  attr :topic, :string, required: true, doc: "presence topic, used by the visibility hook"

  def presence_indicator(assigns) do
    others =
      assigns.viewers
      |> Enum.reject(&(&1.user_id == assigns.current_user_id))
      |> Enum.reject(&(Map.get(&1, :visible?, true) == false))

    max = assigns.max || default_max(assigns.variant)
    visible_viewers = Enum.take(others, max)
    overflow = max(0, length(others) - max)

    assigns =
      assigns
      |> assign(:visible_viewers, visible_viewers)
      |> assign(:overflow, overflow)
      |> assign(:wrapper_id, "presence-" <> assigns.topic)

    ~H"""
    <div
      :if={@visible_viewers != []}
      id={@wrapper_id}
      role="group"
      aria-label={"#{length(@visible_viewers) + @overflow} people viewing"}
      phx-hook=".Visibility"
      data-topic={@topic}
      class={["flex items-center", spacing_class(@variant)]}
    >
      <.viewer_circle :for={viewer <- @visible_viewers} viewer={viewer} variant={@variant} />
      <div
        :if={@overflow > 0}
        class={[
          "rounded-full bg-base-200 text-base-content/70 font-medium",
          "flex items-center justify-center ring-2 ring-base-100",
          size_class(@variant),
          text_class(@variant)
        ]}
      >
        +{@overflow}
      </div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".Visibility">
        export default {
          mounted() {
            this.onChange = () => {
              const event = document.hidden ? "presence:hidden" : "presence:visible"
              this.pushEvent(event, { topic: this.el.dataset.topic })
            }
            document.addEventListener("visibilitychange", this.onChange)
          },
          destroyed() {
            document.removeEventListener("visibilitychange", this.onChange)
          }
        }
      </script>
    </div>
    """
  end

  attr :viewer, :map, required: true
  attr :variant, :atom, required: true

  defp viewer_circle(%{variant: :avatars, viewer: %{avatar_path: path}} = assigns)
       when is_binary(path) do
    assigns = assign(assigns, :avatar_url, avatar_url(path))

    ~H"""
    <img
      src={@avatar_url}
      alt={@viewer.name <> " is viewing"}
      title={@viewer.name}
      aria-label={@viewer.name <> " is viewing"}
      class={[
        size_class(@variant),
        "rounded-full object-cover ring-2 ring-base-100"
      ]}
    />
    """
  end

  defp viewer_circle(assigns) do
    ~H"""
    <div
      title={@viewer.name}
      aria-label={(@viewer.name || "Anonymous") <> " is viewing"}
      style={"background-color: #{@viewer.color}"}
      class={[
        size_class(@variant),
        text_class(@variant),
        "rounded-full text-white font-medium",
        "flex items-center justify-center ring-2 ring-base-100"
      ]}
    >
      {initial(@viewer.name)}
    </div>
    """
  end

  defp default_max(:avatars), do: 5
  defp default_max(:dots), do: 3

  defp size_class(:avatars), do: "w-8 h-8"
  defp size_class(:dots), do: "w-6 h-6"

  defp text_class(:avatars), do: "text-xs"
  defp text_class(:dots), do: "text-[10px]"

  defp spacing_class(:avatars), do: "-space-x-2"
  defp spacing_class(:dots), do: "-space-x-1"

  defp initial(name) when is_binary(name) and name != "" do
    name |> String.first() |> String.upcase()
  end

  defp initial(_), do: "?"

  defp avatar_url(path) do
    case Magus.Files.Storage.get_url(path) do
      {:ok, url} -> url
      _ -> nil
    end
  end
end
