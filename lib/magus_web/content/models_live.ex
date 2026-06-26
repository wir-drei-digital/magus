defmodule MagusWeb.ModelsLive do
  @moduledoc """
  Public models page for discovering available AI models.
  """
  use MagusWeb, :live_view

  alias Magus.Chat.Model.Translations

  on_mount {MagusWeb.LiveUserAuth, :live_user_optional}

  @impl true
  def mount(_params, _session, socket) do
    models = Magus.Chat.list_active_models!()

    providers =
      models |> Enum.map(& &1.provider) |> Enum.uniq() |> Enum.reject(&is_nil/1) |> Enum.sort()

    socket =
      socket
      |> assign(:page_title, gettext("Models"))
      |> assign(:search_query, "")
      |> assign(:filter_provider, nil)
      |> assign(:filter_capability, nil)
      |> assign(:sort_by, :name)
      |> assign(:providers, providers)
      |> assign(:all_models, models)
      |> load_models()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, gettext("Models"))
    |> assign(:show_detail, nil)
  end

  defp apply_action(socket, :show, %{"id" => id}) do
    case Magus.Chat.get_model(id) do
      {:ok, model} ->
        socket
        |> assign(:page_title, model.name)
        |> assign(:show_detail, model)

      {:error, _} ->
        socket
        |> put_flash(:error, gettext("Model not found"))
        |> push_navigate(to: ~p"/models")
    end
  end

  defp load_models(socket) do
    %{
      search_query: query,
      filter_provider: provider,
      filter_capability: capability,
      sort_by: sort_by,
      all_models: all_models
    } = socket.assigns

    models =
      all_models
      |> filter_by_search(query)
      |> filter_by_provider(provider)
      |> filter_by_capability(capability)
      |> sort_models(sort_by)

    stream(socket, :models, models, reset: true)
  end

  defp filter_by_search(models, nil), do: models
  defp filter_by_search(models, ""), do: models

  defp filter_by_search(models, query) do
    query = String.downcase(query)

    Enum.filter(models, fn model ->
      String.contains?(String.downcase(model.name), query) ||
        (model.provider && String.contains?(String.downcase(model.provider), query)) ||
        matches_any_translation?(model.short_description_translations, query) ||
        (model.short_description &&
           String.contains?(String.downcase(model.short_description), query))
    end)
  end

  defp matches_any_translation?(nil, _query), do: false

  defp matches_any_translation?(translations, query) when is_map(translations) do
    translations
    |> Translations.all_translation_values()
    |> Enum.any?(fn value ->
      value && String.contains?(String.downcase(value), query)
    end)
  end

  defp matches_any_translation?(_, _query), do: false

  defp filter_by_provider(models, nil), do: models

  defp filter_by_provider(models, provider) do
    Enum.filter(models, fn model -> model.provider == provider end)
  end

  defp filter_by_capability(models, nil), do: models

  defp filter_by_capability(models, "search") do
    Enum.filter(models, fn model -> model.supports_search? end)
  end

  defp filter_by_capability(models, "reasoning") do
    Enum.filter(models, fn model -> model.supports_reasoning? end)
  end

  defp filter_by_capability(models, "tools") do
    Enum.filter(models, fn model -> model.supports_tools? end)
  end

  defp filter_by_capability(models, "image_input") do
    Enum.filter(models, fn model -> "image" in model.input_modalities end)
  end

  defp filter_by_capability(models, "image_output") do
    Enum.filter(models, fn model -> "image" in model.output_modalities end)
  end

  defp filter_by_capability(models, "video_output") do
    Enum.filter(models, fn model -> "video" in model.output_modalities end)
  end

  defp filter_by_capability(models, _), do: models

  defp sort_models(models, :name) do
    Enum.sort_by(models, & &1.name)
  end

  defp sort_models(models, :released) do
    # Handle nil released_at by putting them at the end
    Enum.sort(models, fn a, b ->
      case {a.released_at, b.released_at} do
        {nil, nil} -> true
        {nil, _} -> false
        {_, nil} -> true
        {date_a, date_b} -> Date.compare(date_a, date_b) != :lt
      end
    end)
  end

  defp sort_models(models, :context) do
    # Handle nil context_window by putting them at the end
    Enum.sort_by(models, fn model -> model.context_window || 0 end, &>=/2)
  end

  defp sort_models(models, :provider) do
    # Sort by provider then name, handling nil providers
    Enum.sort_by(models, fn model -> {model.provider || "", model.name} end)
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    socket =
      socket
      |> assign(:search_query, query)
      |> load_models()

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter_provider", %{"provider" => provider}, socket) do
    provider = if provider == "", do: nil, else: provider

    socket =
      socket
      |> assign(:filter_provider, provider)
      |> load_models()

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter_capability", %{"capability" => capability}, socket) do
    capability = if capability == "", do: nil, else: capability

    socket =
      socket
      |> assign(:filter_capability, capability)
      |> load_models()

    {:noreply, socket}
  end

  @impl true
  def handle_event("sort_by", %{"sort" => sort}, socket) do
    sort_atom = String.to_existing_atom(sort)

    socket =
      socket
      |> assign(:sort_by, sort_atom)
      |> load_models()

    {:noreply, socket}
  end

  @impl true
  def handle_event("close_detail", _, socket) do
    {:noreply, push_navigate(socket, to: ~p"/models")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.content
      flash={@flash}
      current_user={@current_user}
      base_path="/models"
    >
      <div class="container mx-auto px-4 py-6 max-w-7xl">
        <%!-- Header --%>
        <div class="flex flex-col md:flex-row md:items-center justify-between gap-4 mb-6">
          <div>
            <h1 class="text-2xl font-bold text-base-content">{gettext("AI Models")}</h1>
            <p class="text-base-content/60 text-sm mt-1">
              {gettext("Explore available models and their capabilities")}
            </p>
          </div>

          <%!-- Search --%>
          <form phx-change="search" phx-submit="search" class="flex-1 max-w-md">
            <.search_input value={@search_query} placeholder={gettext("Search models...")} />
          </form>
        </div>

        <%!-- Filters Bar --%>
        <div class="flex flex-wrap items-center gap-3 mb-6">
          <%!-- Provider Filter --%>
          <form phx-change="filter_provider" class="flex items-center gap-2">
            <span class="text-sm text-base-content/60">{gettext("Provider:")}</span>
            <select class="select select-sm select-bordered" name="provider">
              <option value="">{gettext("All Providers")}</option>
              <%= for provider <- @providers do %>
                <option value={provider} selected={@filter_provider == provider}>
                  {provider}
                </option>
              <% end %>
            </select>
          </form>

          <%!-- Capability Filter --%>
          <form phx-change="filter_capability" class="flex items-center gap-2">
            <span class="text-sm text-base-content/60">{gettext("Capability:")}</span>
            <select class="select select-sm select-bordered" name="capability">
              <option value="">{gettext("All Capabilities")}</option>
              <option value="search" selected={@filter_capability == "search"}>
                {gettext("Web Search")}
              </option>
              <option value="reasoning" selected={@filter_capability == "reasoning"}>
                {gettext("Reasoning")}
              </option>
              <option value="tools" selected={@filter_capability == "tools"}>
                {gettext("Tool Use")}
              </option>
              <option value="image_input" selected={@filter_capability == "image_input"}>
                {gettext("Image Input")}
              </option>
              <option value="image_output" selected={@filter_capability == "image_output"}>
                {gettext("Image Generation")}
              </option>
              <option value="video_output" selected={@filter_capability == "video_output"}>
                {gettext("Video Generation")}
              </option>
            </select>
          </form>

          <%!-- Sort By --%>
          <form phx-change="sort_by" class="flex items-center gap-2 ml-auto">
            <span class="text-sm text-base-content/60">{gettext("Sort:")}</span>
            <select class="select select-sm select-bordered" name="sort">
              <option value="name" selected={@sort_by == :name}>{gettext("Name")}</option>
              <option value="provider" selected={@sort_by == :provider}>
                {gettext("Provider")}
              </option>
              <option value="released" selected={@sort_by == :released}>
                {gettext("Release Date")}
              </option>
              <option value="context" selected={@sort_by == :context}>
                {gettext("Context Size")}
              </option>
            </select>
          </form>
        </div>

        <%!-- Models Grid --%>
        <div
          id="models"
          phx-update="stream"
          class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4"
        >
          <div :for={{id, model} <- @streams.models} id={id}>
            <.model_card model={model} />
          </div>
        </div>

        <%!-- Empty State --%>
        <%= if @streams.models == [] do %>
          <div class="text-center py-12 text-base-content/50">
            <.icon name="lucide-cpu" class="w-12 h-12 mx-auto mb-4" />
            <p class="text-lg">{gettext("No models found matching your criteria")}</p>
          </div>
        <% end %>
      </div>

      <%!-- Model Detail Modal --%>
      <%= if @show_detail do %>
        <.model_detail_modal model={@show_detail} />
      <% end %>
    </Layouts.content>
    """
  end

  # Model Card Component
  attr :model, :map, required: true

  defp model_card(assigns) do
    ~H"""
    <.link navigate={~p"/models/#{@model.id}"} class="block">
      <div class="library-card hover:ring-2 hover:ring-primary/50 transition-all cursor-pointer h-full">
        <div class="p-4 flex flex-col h-full">
          <%!-- Header --%>
          <div class="flex items-start justify-between gap-2 mb-2">
            <div class="flex items-center gap-2">
              <span class="text-xs font-medium text-primary">{@model.provider}</span>
              <%= if @model.released_at do %>
                <span class="text-xs text-base-content/50">
                  {Calendar.strftime(@model.released_at, "%b %Y")}
                </span>
              <% end %>
            </div>
            <div class="flex gap-1">
              <%= if @model.supports_search? do %>
                <span class="badge badge-info badge-xs" title={gettext("Web Search")}>
                  <.icon name="lucide-globe" class="w-3 h-3" />
                </span>
              <% end %>
              <%= if @model.supports_reasoning? do %>
                <span class="badge badge-warning badge-xs" title={gettext("Reasoning")}>
                  <.icon name="lucide-lightbulb" class="w-3 h-3" />
                </span>
              <% end %>
              <%= if "image" in @model.output_modalities do %>
                <span class="badge badge-secondary badge-xs" title={gettext("Image Generation")}>
                  <.icon name="lucide-image" class="w-3 h-3" />
                </span>
              <% end %>
              <%= if "video" in @model.output_modalities do %>
                <span class="badge badge-accent badge-xs" title={gettext("Video Generation")}>
                  <.icon name="lucide-video" class="w-3 h-3" />
                </span>
              <% end %>
            </div>
          </div>

          <%!-- Title --%>
          <h3 class="font-semibold text-base-content text-lg">{@model.name}</h3>

          <%!-- Short Description --%>
          <% short_desc = Translations.short_description(@model) %>
          <%= if short_desc do %>
            <p class="text-sm text-base-content/70 line-clamp-2 mt-1 flex-grow">
              {short_desc}
            </p>
          <% else %>
            <div class="flex-grow"></div>
          <% end %>

          <%!-- Modalities --%>
          <div class="flex gap-2 mt-3">
            <div class="text-xs text-base-content/50">
              <span class="font-medium">In:</span>
              <%= for modality <- @model.input_modalities do %>
                <span class="badge badge-ghost badge-xs ml-1">{modality_label(modality)}</span>
              <% end %>
            </div>
            <div class="text-xs text-base-content/50">
              <span class="font-medium">Out:</span>
              <%= for modality <- @model.output_modalities do %>
                <span class="badge badge-ghost badge-xs ml-1">{modality_label(modality)}</span>
              <% end %>
            </div>
          </div>

          <%!-- Footer: Pricing & Context --%>
          <div class="flex items-center justify-between mt-3 pt-3 border-t border-base-200 text-xs text-base-content/60">
            <div>
              <%= if @model.context_window do %>
                <.icon name="lucide-file-text" class="w-3 h-3 inline" />
                {format_context_window(@model.context_window)}
              <% end %>
            </div>
            <div class="text-right">
              <%= if @model.input_cost do %>
                <span>{@model.input_cost} in</span>
              <% end %>
              <%= if @model.output_cost do %>
                <span class="ml-1">{@model.output_cost} out</span>
              <% end %>
            </div>
          </div>
        </div>
      </div>
    </.link>
    """
  end

  # Model Detail Modal Component
  attr :model, :map, required: true

  defp model_detail_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-3xl">
        <button
          type="button"
          class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
          phx-click="close_detail"
        >
          <.icon name="lucide-x" class="w-5 h-5" />
        </button>

        <%!-- Header --%>
        <div class="flex items-start gap-4 mb-4">
          <div class="flex-1">
            <div class="flex items-center gap-2 mb-2">
              <span class="badge badge-outline">{@model.provider}</span>
              <%= if @model.released_at do %>
                <span class="text-sm text-base-content/50">
                  Released {Calendar.strftime(@model.released_at, "%B %Y")}
                </span>
              <% end %>
            </div>
            <h2 class="text-2xl font-bold text-base-content">{@model.name}</h2>
            <% short_desc = Translations.short_description(@model) %>
            <%= if short_desc do %>
              <p class="text-base-content/70 mt-1">{short_desc}</p>
            <% end %>
          </div>
        </div>

        <%!-- Capabilities --%>
        <div class="flex flex-wrap gap-2 mb-4">
          <%= if @model.supports_search? do %>
            <span class="badge badge-info gap-1">
              <.icon name="lucide-globe" class="w-4 h-4" /> {gettext("Web Search")}
            </span>
          <% end %>
          <%= if @model.supports_reasoning? do %>
            <span class="badge badge-warning gap-1">
              <.icon name="lucide-lightbulb" class="w-4 h-4" /> {gettext("Reasoning")}
            </span>
          <% end %>
          <%= if @model.supports_tools? do %>
            <span class="badge badge-success gap-1">
              <.icon name="lucide-wrench" class="w-4 h-4" /> {gettext("Tool Use")}
            </span>
          <% end %>
          <%= if "image" in @model.input_modalities do %>
            <span class="badge badge-primary gap-1">
              <.icon name="lucide-eye" class="w-4 h-4" /> {gettext("Vision")}
            </span>
          <% end %>
          <%= if "image" in @model.output_modalities do %>
            <span class="badge badge-secondary gap-1">
              <.icon name="lucide-image" class="w-4 h-4" /> {gettext("Image Generation")}
            </span>
          <% end %>
          <%= if "video" in @model.output_modalities do %>
            <span class="badge badge-accent gap-1">
              <.icon name="lucide-video" class="w-4 h-4" /> {gettext("Video Generation")}
            </span>
          <% end %>
        </div>

        <%!-- Detailed Description --%>
        <% detailed_desc = Translations.detailed_description(@model) %>
        <%= if detailed_desc do %>
          <div class="prose prose-sm max-w-none mb-6">
            <h4 class="text-base font-semibold">{gettext("About this model")}</h4>
            <p>{detailed_desc}</p>
          </div>
        <% end %>

        <%!-- Specs Grid --%>
        <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mb-6">
          <%= if @model.context_window do %>
            <div class="bg-base-200 rounded-lg p-3 text-center">
              <div class="text-xs text-base-content/50 mb-1">{gettext("Context Window")}</div>
              <div class="font-semibold">{format_context_window(@model.context_window)}</div>
            </div>
          <% end %>
          <%= if @model.input_cost do %>
            <div class="bg-base-200 rounded-lg p-3 text-center">
              <div class="text-xs text-base-content/50 mb-1">{gettext("Input Cost")}</div>
              <div class="font-semibold">{@model.input_cost}</div>
            </div>
          <% end %>
          <%= if @model.output_cost do %>
            <div class="bg-base-200 rounded-lg p-3 text-center">
              <div class="text-xs text-base-content/50 mb-1">{gettext("Output Cost")}</div>
              <div class="font-semibold">{@model.output_cost}</div>
            </div>
          <% end %>
          <div class="bg-base-200 rounded-lg p-3 text-center">
            <div class="text-xs text-base-content/50 mb-1">{gettext("Input Types")}</div>
            <div class="font-semibold">
              {Enum.map(@model.input_modalities, &modality_label/1) |> Enum.join(", ")}
            </div>
          </div>
        </div>

        <%!-- Actions --%>
        <div class="modal-action">
          <.link navigate={~p"/chat?model=#{@model.id}"} class="btn btn-primary">
            <.icon name="lucide-messages-square" class="w-5 h-5" /> {gettext(
              "Start Chat with this Model"
            )}
          </.link>
          <button type="button" class="btn" phx-click="close_detail">{gettext("Close")}</button>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="close_detail"></div>
    </div>
    """
  end

  defp modality_label("text"), do: gettext("Text")
  defp modality_label("image"), do: gettext("Image")
  defp modality_label("video"), do: gettext("Video")
  defp modality_label("file"), do: gettext("File")
  defp modality_label(other), do: other

  defp format_context_window(nil), do: "-"
  defp format_context_window(tokens) when tokens >= 1_000_000, do: "#{div(tokens, 1_000_000)}M"
  defp format_context_window(tokens) when tokens >= 1_000, do: "#{div(tokens, 1_000)}K"
  defp format_context_window(tokens), do: "#{tokens}"
end
