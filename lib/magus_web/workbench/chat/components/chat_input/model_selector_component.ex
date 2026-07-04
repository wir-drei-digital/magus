defmodule MagusWeb.ChatLive.Components.ChatInput.ModelSelectorComponent do
  @moduledoc """
  LiveComponent for model and mode selection.

  Handles:
  - Model selection dropdown with provider grouping
  - Mode toggles (search, image generation, video generation)
  - Persists model selections to conversation only (user defaults managed in Settings)

  Uses `phx-target={@myself}` for all events.
  Notifies parent via `notify_parent/1` when selection changes.
  """
  use MagusWeb, :live_component
  use MagusWeb.Live.Shared.ComponentUtils

  alias Magus.Chat.Model.Translations
  alias Magus.Agents.ImageGenerationConfig
  alias Magus.Agents.VideoGenerationConfig
  alias Magus.Usage.PolicyEnforcer

  def render(assigns) do
    ~H"""
    <div class="flex items-center gap-2 flex-wrap">
      <%!-- Mode Toggle Buttons --%>
      <% image_enabled = Map.get(assigns, :image_generation_enabled, true) %>
      <% video_enabled = Map.get(assigns, :video_generation_enabled, true) %>
      <div class="flex items-center gap-1">
        <button
          type="button"
          phx-click={if(image_enabled, do: "toggle_mode", else: "mode_locked")}
          phx-value-mode="image_generation"
          phx-target={@myself}
          class={[
            "btn btn-circle btn-sm",
            cond do
              !image_enabled -> "btn-ghost text-base-content/20 cursor-not-allowed"
              @chat_mode == :image_generation -> "btn-primary"
              true -> "btn-ghost text-base-content/60 hover:text-base-content"
            end
          ]}
          title={
            if(image_enabled,
              do: gettext("Image Generation Mode"),
              else: gettext("Upgrade your plan to unlock image generation")
            )
          }
        >
          <.icon name="lucide-image" class="w-4 h-4" />
        </button>

        <button
          type="button"
          phx-click={if(video_enabled, do: "toggle_mode", else: "mode_locked")}
          phx-value-mode="video_generation"
          phx-target={@myself}
          class={[
            "btn btn-circle btn-sm",
            cond do
              !video_enabled -> "btn-ghost text-base-content/20 cursor-not-allowed"
              @chat_mode == :video_generation -> "btn-primary"
              true -> "btn-ghost text-base-content/60 hover:text-base-content"
            end
          ]}
          title={
            if(video_enabled,
              do: gettext("Video Generation Mode"),
              else: gettext("Upgrade your plan to unlock video generation")
            )
          }
        >
          <.icon name="lucide-film" class="w-4 h-4" />
        </button>
      </div>

      <%!-- Model Selector Dropdown --%>
      <div
        class="dropdown dropdown-top"
        id={"#{@id}-dropdown"}
        phx-hook=".ModelDropdownFocus"
        data-search-input={"#{@id}-search-input"}
      >
        <div
          tabindex="0"
          role="button"
          class="btn btn-sm btn-ghost gap-2 text-base-content/80 hover:text-base-content"
        >
          <span class="text-xs">
            {(@selected_model && @selected_model.name) || gettext("Auto")}
          </span>
          <.icon name="lucide-chevron-up" class="w-3 h-3" />
        </div>
        <div
          tabindex="0"
          class="dropdown-content bg-base-200 rounded-lg shadow-lg z-50 p-2 w-96 max-h-80 overflow-y-auto overscroll-contain border-1 border-base-300"
        >
          <div class="flex flex-col gap-2">
            <input
              type="text"
              placeholder={gettext("Search models...")}
              value={@search_query}
              phx-change="search_models"
              phx-target={@myself}
              phx-debounce="100"
              name="query"
              id={"#{@id}-search-input"}
              phx-hook=".ModelSearchKeyboard"
              class="input input-sm bg-base-200 border border-base-300 rounded-lg text-base-content placeholder:text-base-content/40 focus:outline-none focus:ring-2 focus:ring-primary/50 focus:border-primary transition-colors w-full text-xs mb-1"
            />
            <%!-- Auto option --%>
            <button
              type="button"
              phx-click="select_auto"
              phx-target={@myself}
              phx-hook=".ModelSelectButton"
              id={"#{@id}-model-auto"}
              class={[
                "flex flex-col items-start gap-0.5 p-2 rounded-lg transition-colors text-left",
                if(is_nil(@selected_model_id),
                  do: "bg-primary/10 ring-1 ring-primary",
                  else: "bg-base-100 hover:bg-base-300"
                )
              ]}
            >
              <div class="flex items-center gap-1.5 w-full">
                <.icon name="lucide-sparkles" class="w-3.5 h-3.5 text-primary" />
                <span class="font-medium text-xs">{gettext("Auto")}</span>
              </div>
              <span class="text-[10px] text-base-content/50 line-clamp-1 w-full">
                {gettext("Automatically selects the model for you")}
              </span>
            </button>
            <div :for={{provider, models} <- @models_by_provider} class="flex flex-col gap-2 p-1">
              <div class="text-[10px] text-base-content/50 font-medium uppercase tracking-wider px-2">
                {provider}
              </div>
              <button
                :for={model <- models}
                type="button"
                id={"#{@id}-model-#{model.id}"}
                phx-click="select_model"
                phx-value-model_id={model.id}
                phx-target={@myself}
                phx-hook=".ModelSelectButton"
                class={[
                  "flex flex-col items-start gap-0.5 p-2 rounded-lg transition-colors text-left",
                  if(model.id == @selected_model_id,
                    do: "bg-primary/10 ring-1 ring-primary",
                    else: "bg-base-100"
                  ),
                  "hover:bg-base-300"
                ]}
              >
                <div class="flex items-center gap-1 w-full">
                  <span class="font-medium text-xs truncate">{model.name}</span>
                  <% cost = request_cost_display(model) %>
                  <span
                    :if={cost}
                    data-test-model-cost={model.key}
                    data-test-model-cost-tier={elem(cost, 1)}
                    class={[
                      "text-[10px] ml-auto shrink-0 font-normal whitespace-nowrap",
                      cost_tier_class(elem(cost, 1))
                    ]}
                  >
                    {elem(cost, 0)}
                  </span>
                </div>
                <span
                  :if={Translations.short_description(model)}
                  class="text-[10px] text-base-content/50 line-clamp-1 w-full"
                >
                  {Translations.short_description(model)}
                </span>
                <div class="flex items-center gap-1 w-full">
                  <span
                    :for={modality <- model.input_modalities || ["text"]}
                    class="badge badge-xs badge-ghost text-[9px] px-1"
                  >
                    {modality_icon(modality)}
                  </span>
                  <span class="text-base-content/30 text-[10px]">→</span>
                  <span
                    :for={modality <- model.output_modalities || ["text"]}
                    class={[
                      "badge badge-xs text-[9px] px-1",
                      if(modality == "image", do: "badge-secondary", else: "badge-ghost")
                    ]}
                  >
                    {modality_icon(modality)}
                  </span>
                  <span
                    :if={model.supports_search?}
                    class="badge badge-xs badge-info text-[9px] px-1"
                  >
                    search
                  </span>
                  <span
                    :if={model.supports_reasoning?}
                    class="badge badge-xs badge-warning text-[9px] px-1"
                  >
                    reason
                  </span>
                  <% per_million = model_cost_label(model) %>
                  <span
                    :if={per_million || model.context_window}
                    class="text-[9px] text-base-content/40 ml-auto flex items-center gap-1 whitespace-nowrap"
                  >
                    <span :if={per_million} data-test-model-cost-permillion={model.key}>
                      {per_million}
                    </span>
                    <span :if={per_million && model.context_window} aria-hidden="true">·</span>
                    <span :if={model.context_window}>
                      {format_context_window(model.context_window)}
                    </span>
                  </span>
                </div>
              </button>
            </div>
          </div>
        </div>
      </div>

      <%!-- Image Generation Config Dropdown --%>
      <div :if={@chat_mode == :image_generation} class="dropdown dropdown-top">
        <div
          tabindex="0"
          role="button"
          class="btn btn-sm btn-ghost gap-2 text-base-content/80 hover:text-base-content"
        >
          <.icon name="lucide-sliders-horizontal" class="w-3.5 h-3.5" />
          <span class="text-xs">{@image_aspect_ratio} / {@image_size}</span>
          <.icon name="lucide-chevron-up" class="w-3 h-3" />
        </div>
        <div
          tabindex="0"
          class="dropdown-content bg-base-200 rounded-lg shadow-lg z-50 p-3 w-56 border-1 border-base-300"
        >
          <div class="flex flex-col gap-3">
            <div class="flex flex-col gap-1">
              <label class="text-[10px] text-base-content/50 font-medium uppercase tracking-wider">
                {gettext("Aspect Ratio")}
              </label>
              <select
                name="image_aspect_ratio"
                phx-change="update_image_config"
                phx-target={@myself}
                class="select select-sm select-bordered w-full text-xs"
              >
                <option
                  :for={ratio <- @aspect_ratios}
                  value={ratio}
                  selected={ratio == @image_aspect_ratio}
                >
                  {ratio}
                </option>
              </select>
            </div>
            <div class="flex flex-col gap-1">
              <label class="text-[10px] text-base-content/50 font-medium uppercase tracking-wider">
                {gettext("Resolution")}
              </label>
              <select
                name="image_size"
                phx-change="update_image_config"
                phx-target={@myself}
                class="select select-sm select-bordered w-full text-xs"
              >
                <option
                  :for={size <- @image_sizes}
                  value={size}
                  selected={size == @image_size}
                >
                  {size}
                </option>
              </select>
            </div>
          </div>
        </div>
      </div>

      <%!-- Video Generation Config Dropdown --%>
      <div :if={@chat_mode == :video_generation} class="dropdown dropdown-top">
        <div
          tabindex="0"
          role="button"
          class="btn btn-sm btn-ghost gap-2 text-base-content/80 hover:text-base-content"
        >
          <.icon name="lucide-sliders-horizontal" class="w-3.5 h-3.5" />
          <span class="text-xs">
            {video_config_summary(assigns)}
          </span>
          <.icon name="lucide-chevron-up" class="w-3 h-3" />
        </div>
        <div
          tabindex="0"
          class="dropdown-content bg-base-200 rounded-lg shadow-lg z-50 p-3 w-56 border-1 border-base-300"
        >
          <div class="flex flex-col gap-3">
            <div :if={@video_aspect_ratios} class="flex flex-col gap-1">
              <label class="text-[10px] text-base-content/50 font-medium uppercase tracking-wider">
                {gettext("Aspect Ratio")}
              </label>
              <select
                name="video_aspect_ratio"
                phx-change="update_video_config"
                phx-target={@myself}
                class="select select-sm select-bordered w-full text-xs"
              >
                <option
                  :for={ratio <- @video_aspect_ratios}
                  value={ratio}
                  selected={ratio == @video_aspect_ratio}
                >
                  {ratio}
                </option>
              </select>
            </div>
            <div :if={@video_durations} class="flex flex-col gap-1">
              <label class="text-[10px] text-base-content/50 font-medium uppercase tracking-wider">
                {gettext("Duration")}
              </label>
              <select
                name="video_duration"
                phx-change="update_video_config"
                phx-target={@myself}
                class="select select-sm select-bordered w-full text-xs"
              >
                <option
                  :for={dur <- @video_durations}
                  value={dur}
                  selected={dur == @video_duration}
                >
                  {dur}s
                </option>
              </select>
            </div>
            <div :if={@video_resolutions} class="flex flex-col gap-1">
              <label class="text-[10px] text-base-content/50 font-medium uppercase tracking-wider">
                {gettext("Resolution")}
              </label>
              <select
                name="video_resolution"
                phx-change="update_video_config"
                phx-target={@myself}
                class="select select-sm select-bordered w-full text-xs"
              >
                <option
                  :for={res <- @video_resolutions}
                  value={res}
                  selected={res == @video_resolution}
                >
                  {res}
                </option>
              </select>
            </div>
            <div :if={@video_has_audio} class="flex flex-col gap-1">
              <label class="text-[10px] text-base-content/50 font-medium uppercase tracking-wider">
                {gettext("Audio")}
              </label>
              <label class="flex items-center gap-2 cursor-pointer py-1">
                <input
                  type="checkbox"
                  name="video_generate_audio"
                  phx-change="update_video_config"
                  phx-target={@myself}
                  checked={@video_generate_audio}
                  class="checkbox checkbox-sm checkbox-primary"
                />
                <span class="text-xs text-base-content/80">{gettext("Generate audio track")}</span>
              </label>
            </div>
          </div>
        </div>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".ModelDropdownFocus">
        export default {
          mounted() {
            const inputId = this.el.dataset.searchInput;
            const trigger = this.el.querySelector('[role="button"]');
            const content = this.el.querySelector('.dropdown-content');

            // Only auto-focus the search input when the trigger itself gets focus
            // (not when elements inside the content area get focus).
            // This fixes the Safari bug where clicking a model button inside the
            // scrollable content focused the parent div, retriggering auto-focus
            // and scrolling the list back to the top.
            this.el.addEventListener('focusin', (e) => {
              if (e.target !== trigger && e.target !== this.el) return;

              // On small screens, center horizontally using absolute positioning
              // (keep position:absolute so scroll events work correctly)
              if (content && window.innerWidth < 640) {
                const dropdownRect = this.el.getBoundingClientRect();
                const contentWidth = Math.min(window.innerWidth - 32, 320);
                const centerLeft = (window.innerWidth - contentWidth) / 2 - dropdownRect.left;
                content.style.left = centerLeft + 'px';
                content.style.width = contentWidth + 'px';
              }

              setTimeout(() => {
                const input = document.getElementById(inputId);
                if (input) input.focus();
              }, 10);
            });

            // Reset mobile styles when focus leaves the dropdown entirely
            this.el.addEventListener('focusout', (e) => {
              if (!this.el.contains(e.relatedTarget) && content) {
                content.style.left = '';
                content.style.width = '';
              }
            });

            // Safari/iOS fix: prevent mousedown inside the content from moving
            // focus away from the search input. Without this, Safari (which does
            // not focus buttons on click) moves focus to the scrollable content
            // div, triggering the auto-focus handler above and scrolling to top.
            // The click event still fires normally on buttons after this.
            if (content) {
              content.addEventListener('mousedown', (e) => {
                // Only prevent default on button clicks (not the scrollable area)
                // to preserve native scrolling while fixing Safari focus issues.
                if (e.target.closest('button')) {
                  e.preventDefault();
                }
              });

              // Contain scroll within the dropdown: prevent wheel/touch events
              // from bubbling to the window-level AutoScroll hook, which would
              // otherwise scroll the main page instead of the dropdown.
              content.addEventListener('wheel', (e) => {
                e.preventDefault();
                e.stopPropagation();
                content.scrollTop += e.deltaY;
              }, { passive: false });

              let touchY = null;
              content.addEventListener('touchstart', (e) => {
                touchY = e.touches[0].clientY;
              }, { passive: true });
              content.addEventListener('touchmove', (e) => {
                if (touchY !== null) {
                  const delta = touchY - e.touches[0].clientY;
                  const atTop = content.scrollTop <= 0;
                  const atBottom = content.scrollTop + content.clientHeight >= content.scrollHeight;
                  if ((delta < 0 && atTop) || (delta > 0 && atBottom)) {
                    e.preventDefault();
                  }
                  e.stopPropagation();
                  touchY = e.touches[0].clientY;
                }
              }, { passive: false });
            }
          }
        }
      </script>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".ModelSelectButton">
        export default {
          mounted() {
            this.el.addEventListener('click', () => {
              // Immediately blur to close the dropdown before LiveView re-renders,
              // preventing a flicker where the dropdown briefly shows in its
              // default CSS position during the re-render.
              if (document.activeElement) document.activeElement.blur();

              setTimeout(() => {
                const chatInput = document.querySelector('textarea[name="content"]') ||
                                 document.querySelector('#chat-input') ||
                                 document.querySelector('textarea');
                if (chatInput) chatInput.focus();
              }, 50);
            });
          }
        }
      </script>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".ModelSearchKeyboard">
        export default {
          mounted() {
            this.highlightedIndex = -1;

            this.el.addEventListener('keydown', (e) => {
              const dropdown = this.el.closest('.dropdown');
              const buttons = dropdown.querySelectorAll('button[phx-click="select_model"]:not([disabled]), button[phx-click="select_auto"]');

              if (buttons.length === 0) return;

              if (e.key === 'ArrowDown') {
                e.preventDefault();
                this.highlightedIndex = Math.min(this.highlightedIndex + 1, buttons.length - 1);
                this.updateHighlight(buttons);
              } else if (e.key === 'ArrowUp') {
                e.preventDefault();
                this.highlightedIndex = Math.max(this.highlightedIndex - 1, 0);
                this.updateHighlight(buttons);
              } else if (e.key === 'Enter' || e.key === ' ') {
                if (this.highlightedIndex >= 0 && buttons[this.highlightedIndex]) {
                  e.preventDefault();
                  buttons[this.highlightedIndex].click();
                  this.focusChat();
                }
              } else if (e.key === 'Escape') {
                e.preventDefault();
                this.focusChat();
              }
            });
          },

          updateHighlight(buttons) {
            buttons.forEach((btn, i) => {
              if (i === this.highlightedIndex) {
                btn.classList.add('ring-2', 'ring-primary');
                btn.scrollIntoView({ block: 'nearest' });
              } else {
                btn.classList.remove('ring-2', 'ring-primary');
              }
            });
          },

          focusChat() {
            this.highlightedIndex = -1;
            setTimeout(() => {
              const chatInput = document.querySelector('textarea[name="content"]') ||
                               document.querySelector('#chat-input') ||
                               document.querySelector('textarea');
              if (chatInput) chatInput.focus();
            }, 50);
          }
        }
      </script>
    </div>
    """
  end

  def mount(socket) do
    {:ok, socket}
  end

  def update(assigns, socket) do
    models = assigns[:models] || []
    selected_model_id = assigns[:selected_model_id]
    search_query = socket.assigns[:search_query] || ""

    filtered_models = filter_models(models, search_query)
    selected_model = get_selected_model(models, selected_model_id)

    # Extract image generation settings from assigns or keep existing
    image_settings =
      assigns[:image_generation_settings] || socket.assigns[:image_generation_settings] || %{}

    # Extract video generation settings from assigns or keep existing
    video_settings =
      assigns[:video_generation_settings] || socket.assigns[:video_generation_settings] || %{}

    # Derive video option lists from selected model's options field
    chat_mode = assigns[:chat_mode] || socket.assigns[:chat_mode]

    model_options =
      if chat_mode == :video_generation && selected_model && selected_model.options do
        selected_model.options
      else
        nil
      end

    # nil = use full fallback lists (Auto mode or non-video mode)
    # model_options map present = use model-specific lists, nil for unsupported options
    video_ar_options =
      if model_options,
        do: model_options["aspect_ratio"],
        else: VideoGenerationConfig.aspect_ratios()

    video_dur_options =
      if model_options, do: model_options["duration"], else: VideoGenerationConfig.durations()

    video_res_options =
      if model_options, do: model_options["resolution"], else: VideoGenerationConfig.resolutions()

    video_has_audio =
      if model_options, do: Map.has_key?(model_options, "generate_audio"), else: true

    # Validate current values against available options — reset to first if invalid
    video_ar =
      if video_ar_options && video_settings["aspect_ratio"] in video_ar_options,
        do: video_settings["aspect_ratio"],
        else: (video_ar_options && List.first(video_ar_options)) || "16:9"

    video_dur =
      if video_dur_options && video_settings["duration"] in video_dur_options,
        do: video_settings["duration"],
        else: (video_dur_options && List.first(video_dur_options)) || "5"

    video_res =
      if video_res_options && video_settings["resolution"] in video_res_options,
        do: video_settings["resolution"],
        else: (video_res_options && List.first(video_res_options)) || "720p"

    socket =
      socket
      |> assign(assigns)
      |> assign(:search_query, search_query)
      |> assign(:selected_model, selected_model)
      |> assign(:models_by_provider, Enum.group_by(filtered_models, & &1.provider))
      |> assign(:aspect_ratios, ImageGenerationConfig.aspect_ratios())
      |> assign(:image_sizes, ImageGenerationConfig.image_sizes())
      |> assign(:image_aspect_ratio, image_settings["aspect_ratio"] || "1:1")
      |> assign(:image_size, image_settings["image_size"] || "1K")
      |> assign(:image_generation_settings, image_settings)
      |> assign(:video_aspect_ratios, video_ar_options)
      |> assign(:video_durations, video_dur_options)
      |> assign(:video_resolutions, video_res_options)
      |> assign(:video_has_audio, video_has_audio)
      |> assign(:video_aspect_ratio, video_ar)
      |> assign(:video_duration, video_dur)
      |> assign(:video_resolution, video_res)
      |> assign(:video_generate_audio, video_settings["generate_audio"] != false)
      |> assign(:video_generation_settings, video_settings)

    {:ok, socket}
  end

  def handle_event("select_auto", _params, socket) do
    mode = socket.assigns.chat_mode

    # Only persist to conversation (not user defaults)
    if socket.assigns.conversation do
      case mode do
        :image_generation ->
          Magus.Chat.set_conversation_image_model!(
            socket.assigns.conversation,
            %{selected_image_model_id: nil},
            actor: socket.assigns.current_user
          )

        :video_generation ->
          Magus.Chat.set_conversation_video_model!(
            socket.assigns.conversation,
            %{selected_video_model_id: nil},
            actor: socket.assigns.current_user
          )

        _ ->
          Magus.Chat.set_conversation_model!(
            socket.assigns.conversation,
            %{selected_model_id: nil},
            actor: socket.assigns.current_user
          )
      end
    end

    notify_parent({:model_selected, nil, mode, socket.assigns[:input_context] || :main})

    socket =
      socket
      |> assign(:selected_model_id, nil)
      |> assign(:selected_model, nil)

    {:noreply, socket}
  end

  def handle_event("select_model", %{"model_id" => model_id}, socket) do
    do_select_model(socket, model_id)
  end

  def handle_event("search_models", %{"query" => query}, socket) do
    filtered_models = filter_models(socket.assigns.models, query)

    socket =
      socket
      |> assign(:search_query, query)
      |> assign(:models_by_provider, Enum.group_by(filtered_models, & &1.provider))

    {:noreply, socket}
  end

  def handle_event("update_image_config", params, socket) do
    # Merge current values with whichever select changed
    aspect_ratio = params["image_aspect_ratio"] || socket.assigns.image_aspect_ratio
    image_size = params["image_size"] || socket.assigns.image_size

    settings = %{"aspect_ratio" => aspect_ratio, "image_size" => image_size}

    # Persist to user (global default)
    Magus.Accounts.update_image_generation_settings!(
      socket.assigns.current_user,
      %{image_generation_settings: settings},
      actor: socket.assigns.current_user
    )

    # Persist to conversation if one exists
    if socket.assigns.conversation do
      Magus.Chat.update_image_generation_settings!(
        socket.assigns.conversation,
        %{image_generation_settings: settings},
        actor: socket.assigns.current_user
      )
    end

    notify_parent({:image_config_changed, settings})

    socket =
      socket
      |> assign(:image_aspect_ratio, aspect_ratio)
      |> assign(:image_size, image_size)
      |> assign(:image_generation_settings, settings)

    {:noreply, socket}
  end

  def handle_event("update_video_config", params, socket) do
    aspect_ratio = params["video_aspect_ratio"] || socket.assigns.video_aspect_ratio
    duration = params["video_duration"] || socket.assigns.video_duration
    resolution = params["video_resolution"] || socket.assigns.video_resolution

    generate_audio =
      if params["_target"] == ["video_generate_audio"] do
        # Checkbox toggled: present in params = checked, absent = unchecked
        params["video_generate_audio"] == "true"
      else
        socket.assigns.video_generate_audio
      end

    settings = %{
      "aspect_ratio" => aspect_ratio,
      "duration" => duration,
      "resolution" => resolution,
      "generate_audio" => generate_audio
    }

    # Persist to user (global default)
    Magus.Accounts.update_video_generation_settings!(
      socket.assigns.current_user,
      %{video_generation_settings: settings},
      actor: socket.assigns.current_user
    )

    # Persist to conversation if one exists
    if socket.assigns.conversation do
      Magus.Chat.update_video_generation_settings!(
        socket.assigns.conversation,
        %{video_generation_settings: settings},
        actor: socket.assigns.current_user
      )
    end

    notify_parent({:video_config_changed, settings})

    socket =
      socket
      |> assign(:video_aspect_ratio, aspect_ratio)
      |> assign(:video_duration, duration)
      |> assign(:video_resolution, resolution)
      |> assign(:video_generate_audio, generate_audio)
      |> assign(:video_generation_settings, settings)

    {:noreply, socket}
  end

  def handle_event("mode_locked", %{"mode" => mode}, socket) do
    mode = String.to_existing_atom(mode)
    notify_parent({:mode_locked, mode})
    {:noreply, socket}
  end

  def handle_event("toggle_mode", %{"mode" => mode}, socket) do
    mode = String.to_existing_atom(mode)

    # Toggle off if already active, otherwise set
    new_mode = if socket.assigns.chat_mode == mode, do: :chat, else: mode

    # Persist to conversation if one exists
    if socket.assigns.conversation do
      Magus.Chat.set_conversation_mode!(socket.assigns.conversation, %{chat_mode: new_mode},
        actor: socket.assigns.current_user
      )
    end

    # Get selected_model_id based on mode
    selected_model_id =
      case new_mode do
        :image_generation -> socket.assigns.selected_image_model_id
        :video_generation -> socket.assigns.selected_video_model_id
        _ -> socket.assigns.selected_chat_model_id
      end

    notify_parent(
      {:mode_changed, new_mode, selected_model_id, socket.assigns[:input_context] || :main}
    )

    socket =
      socket
      |> assign(:chat_mode, new_mode)
      |> assign(:selected_model_id, selected_model_id)
      |> assign(:selected_model, get_selected_model(socket.assigns.models, selected_model_id))

    {:noreply, socket}
  end

  # Private helpers

  defp do_select_model(socket, model_id) do
    mode = socket.assigns.chat_mode

    if socket.assigns.conversation do
      case mode do
        :image_generation ->
          Magus.Chat.set_conversation_image_model!(
            socket.assigns.conversation,
            %{selected_image_model_id: model_id},
            actor: socket.assigns.current_user
          )

        :video_generation ->
          Magus.Chat.set_conversation_video_model!(
            socket.assigns.conversation,
            %{selected_video_model_id: model_id},
            actor: socket.assigns.current_user
          )

        _ ->
          Magus.Chat.set_conversation_model!(
            socket.assigns.conversation,
            %{selected_model_id: model_id},
            actor: socket.assigns.current_user
          )
      end
    end

    notify_parent({:model_selected, model_id, mode, socket.assigns[:input_context] || :main})

    socket =
      socket
      |> assign(:selected_model_id, model_id)
      |> assign(:selected_model, get_selected_model(socket.assigns.models, model_id))

    {:noreply, socket}
  end

  defp get_selected_model(models, selected_id) do
    Enum.find(models, fn m -> m.id == selected_id end)
  end

  defp modality_icon("text"), do: "T"
  defp modality_icon("image"), do: "img"
  defp modality_icon("video"), do: "vid"
  defp modality_icon("file"), do: "file"
  defp modality_icon(other), do: other

  defp format_context_window(nil), do: nil

  defp format_context_window(tokens) when tokens >= 1_000_000 do
    "#{Float.round(tokens / 1_000_000, 1)}M ctx"
  end

  defp format_context_window(tokens) when tokens >= 1_000 do
    "#{div(tokens, 1_000)}K ctx"
  end

  defp format_context_window(tokens), do: "#{tokens} ctx"

  defp filter_models(models, ""), do: models
  defp filter_models(models, nil), do: models

  defp filter_models(models, query) do
    query = String.downcase(query)

    Enum.filter(models, fn model ->
      String.contains?(String.downcase(model.name || ""), query) ||
        String.contains?(String.downcase(model.provider || ""), query) ||
        matches_any_translation?(model.short_description_translations, query) ||
        String.contains?(String.downcase(model.short_description || ""), query)
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

  # ── Approximate cost per request (composer model picker) ──────────────────
  # Token models show a per-request CHF estimate top-right, color-coded by tier.
  # Media (image/video) models return nil here and show their per-unit price in
  # the footer instead. The calculation + thresholds live in PolicyEnforcer so
  # the workbench and SPA pickers stay in sync.
  #
  # Returns `{label, tier}` for token models, or nil when there is no per-request
  # token estimate.
  defp request_cost_display(model) do
    case PolicyEnforcer.picker_request_cost_cents(model) do
      nil ->
        nil

      cents ->
        {"≈ CHF " <> :erlang.float_to_binary(cents / 100, decimals: 2),
         PolicyEnforcer.request_cost_tier(cents)}
    end
  end

  defp cost_tier_class(:cheap), do: "text-success"
  defp cost_tier_class(:moderate), do: "text-warning"
  defp cost_tier_class(:expensive), do: "text-error"
  defp cost_tier_class(_), do: "text-base-content/40"

  # Compact, unobtrusive per-model cost label, e.g. "in $2 / out $12".
  # Prefers the pre-formatted `input_cost`/`output_cost` strings and falls back
  # to formatting the numeric `*_cost_value` with the unit. Returns nil when no
  # cost information is available, so the caller can render nothing.
  defp model_cost_label(model) do
    input = cost_part(model.input_cost, model.input_cost_value, model.input_cost_unit)
    output = cost_part(model.output_cost, model.output_cost_value, model.output_cost_unit)

    case {input, output} do
      {nil, nil} -> nil
      {input, nil} -> gettext("in %{cost}", cost: input)
      {nil, output} -> gettext("out %{cost}", cost: output)
      {input, output} -> gettext("in %{in} / out %{out}", in: input, out: output)
    end
  end

  defp cost_part(string, value, unit) when is_binary(string) do
    case String.trim(string) do
      "" -> cost_part(nil, value, unit)
      trimmed -> trimmed
    end
  end

  defp cost_part(_string, %Decimal{} = value, unit),
    do: format_cost_value(Decimal.normalize(value), unit)

  defp cost_part(_string, _value, _unit), do: nil

  defp format_cost_value(value, :per_second), do: "$#{Decimal.to_string(value, :normal)}/s"
  defp format_cost_value(value, :per_image), do: "$#{Decimal.to_string(value, :normal)}/img"
  defp format_cost_value(value, :per_video), do: "$#{Decimal.to_string(value, :normal)}/vid"
  defp format_cost_value(value, :per_megapixel), do: "$#{Decimal.to_string(value, :normal)}/MP"
  defp format_cost_value(value, _unit), do: "$#{Decimal.to_string(value, :normal)}/M"

  defp video_config_summary(assigns) do
    parts =
      []
      |> then(fn parts ->
        if assigns[:video_aspect_ratios], do: parts ++ [assigns.video_aspect_ratio], else: parts
      end)
      |> then(fn parts ->
        if assigns[:video_durations], do: parts ++ ["#{assigns.video_duration}s"], else: parts
      end)
      |> then(fn parts ->
        if assigns[:video_resolutions], do: parts ++ [assigns.video_resolution], else: parts
      end)

    Enum.join(parts, " / ")
  end
end
