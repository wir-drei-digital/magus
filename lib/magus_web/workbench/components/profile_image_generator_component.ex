defmodule MagusWeb.ProfileImageGeneratorComponent do
  @moduledoc """
  Reusable LiveComponent for generating profile images via AI.

  Generates a 1:1 image using the default image model and stores it
  in the configured storage backend. Notifies the parent with the
  stored image path on completion.

  ## Events sent to parent

  - `{ProfileImageGeneratorComponent, {:image_generated, path}}` - On success
  - `{ProfileImageGeneratorComponent, {:task_started, ref}}` - When generation starts
  - `{ProfileImageGeneratorComponent, :cancelled}` - When modal closed

  ## Required assigns

  - `id` - Component ID
  - `show` - Boolean to control modal visibility
  - `storage_prefix` - Storage directory prefix (e.g., "avatars", "agent_images")
  - `entity_id` - ID used in the filename

  ## Optional assigns

  - `current_image_url` - URL of current image for preview
  """

  use MagusWeb, :live_component
  use MagusWeb.Live.Shared.ComponentUtils

  alias Magus.Agents.Providers.OpenRouterImage
  alias Magus.Files.Storage

  require Logger

  @styles [
    {:none, "None", ""},
    {:photo, "Photo Realistic",
     ", photorealistic style, hyper-detailed, natural lighting, realistic textures"},
    {:flat, "Flat", ", flat illustration style, clean vector art, simple shapes, bold colors"},
    {:pixel, "Pixel Art", ", pixel art style, retro 8-bit game aesthetic, crisp pixels"},
    {:threeD, "3D", ", 3D rendered style, smooth lighting, soft shadows, clay-like material"},
    {:cartoon, "Cartoon", ", cartoon style, expressive, bold outlines, vibrant colors"},
    {:emoji, "Emoji",
     ", emoji style, round expressive character, bold simple shapes, yellow skin tone"},
    {:minimal, "Minimal",
     ", minimalist style, simple geometry, limited color palette, clean lines"},
    {:watercolor, "Watercolor",
     ", watercolor painting style, soft edges, blended colors, artistic texture"}
  ]

  def render(assigns) do
    ~H"""
    <div>
      <.modal
        id={"#{@id}-modal"}
        show={@show}
        on_close="cancel"
        target={@myself}
        size={:md}
      >
        <:title>{gettext("Generate Profile Image")}</:title>

        <.form for={%{}} phx-change="update_form" phx-submit="generate" phx-target={@myself}>
          <div class="space-y-4">
            <%!-- Preview --%>
            <div class="flex justify-center">
              <div class="w-32 h-32 rounded-xl bg-base-200 flex items-center justify-center overflow-hidden border border-base-300">
                <img
                  :if={@preview_url}
                  src={@preview_url}
                  class="w-full h-full object-cover"
                />
                <img
                  :if={!@preview_url && @current_image_url}
                  src={@current_image_url}
                  class="w-full h-full object-cover"
                />
                <.icon
                  :if={!@preview_url && !@current_image_url}
                  name="lucide-image"
                  class="w-10 h-10 text-base-content/20"
                />
              </div>
            </div>

            <%!-- Prompt --%>
            <.input
              type="text"
              value={@prompt}
              name="prompt"
              label={gettext("Describe the image")}
              placeholder={gettext("A friendly robot mascot...")}
              disabled={@generating}
            />

            <%!-- Style selector --%>
            <div class="fieldset mb-2">
              <span class="label mb-1">{gettext("Style")}</span>
              <div class="flex flex-wrap gap-2">
                <button
                  :for={{key, label, _suffix} <- @styles}
                  type="button"
                  phx-click="select_style"
                  phx-value-style={key}
                  phx-target={@myself}
                  disabled={@generating}
                  class={"btn btn-sm #{if @selected_style == key, do: "btn-primary", else: "btn-ghost border-base-300"}"}
                >
                  {label}
                </button>
              </div>
            </div>

            <%!-- Error --%>
            <div :if={@error} class="alert alert-error alert-sm">
              <.icon name="lucide-alert-circle" class="w-4 h-4" />
              <span>{@error}</span>
            </div>
          </div>

          <div class="modal-action">
            <button type="button" class="btn" phx-click="cancel" phx-target={@myself}>
              {gettext("Cancel")}
            </button>
            <button
              type="submit"
              class="btn btn-secondary"
              disabled={@generating || @prompt == ""}
            >
              <span :if={@generating} class="loading loading-spinner loading-sm"></span>
              <.icon :if={!@generating} name="lucide-wand-2" class="w-4 h-4" />
              {if @preview_url, do: gettext("Regenerate"), else: gettext("Generate")}
            </button>
            <button
              :if={@preview_url}
              type="button"
              class="btn btn-primary"
              phx-click="save_image"
              phx-target={@myself}
            >
              <.icon name="lucide-check" class="w-4 h-4" />
              {gettext("Use this image")}
            </button>
          </div>
        </.form>
      </.modal>
    </div>
    """
  end

  def mount(socket) do
    {:ok,
     socket
     |> assign(:show, false)
     |> assign(:prompt, "")
     |> assign(:selected_style, :none)
     |> assign(:generating, false)
     |> assign(:preview_url, nil)
     |> assign(:preview_binary, nil)
     |> assign(:error, nil)
     |> assign(:current_image_url, nil)
     |> assign(:styles, @styles)}
  end

  def update(%{task_result: {:ok, %{images: [first | _]}}}, socket) do
    data_url = first["data_url"]

    case decode_data_url(data_url) do
      {:ok, _mime, binary} ->
        {:ok,
         socket
         |> assign(:generating, false)
         |> assign(:preview_url, data_url)
         |> assign(:preview_binary, binary)
         |> assign(:error, nil)}

      :error ->
        {:ok,
         socket
         |> assign(:generating, false)
         |> assign(:error, gettext("Failed to decode the generated image"))}
    end
  end

  def update(%{task_result: {:ok, %{images: []}}}, socket) do
    {:ok,
     socket
     |> assign(:generating, false)
     |> assign(:error, gettext("No image was generated. Try a different prompt."))}
  end

  def update(%{task_result: {:error, reason}}, socket) do
    Logger.error("Profile image generation failed: #{inspect(reason)}")

    {:ok,
     socket
     |> assign(:generating, false)
     |> assign(:error, gettext("Generation failed. Please try again."))}
  end

  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  def handle_event("update_form", %{"prompt" => prompt}, socket) do
    {:noreply, assign(socket, :prompt, prompt)}
  end

  def handle_event("select_style", %{"style" => style}, socket) do
    {:noreply, assign(socket, :selected_style, String.to_existing_atom(style))}
  end

  def handle_event("generate", %{"prompt" => prompt}, socket) do
    socket = assign(socket, :prompt, prompt)

    if prompt == "" do
      {:noreply, assign(socket, :error, gettext("Please enter a prompt"))}
    else
      {_key, _label, suffix} =
        Enum.find(@styles, fn {k, _, _} -> k == socket.assigns.selected_style end)

      full_prompt =
        "Generate a profile picture/avatar: #{prompt}#{suffix}. Square format, centered subject, clean background."

      model_key = Magus.Models.Roles.resolve(:image_default)

      messages = [%{"role" => "user", "content" => full_prompt}]

      task =
        Task.Supervisor.async_nolink(Magus.AgentLoopTaskSupervisor, fn ->
          OpenRouterImage.generate_image(model_key, messages,
            image_config: %{"aspect_ratio" => "1:1", "image_size" => "1K"}
          )
        end)

      send(self(), {__MODULE__, {:task_started, task.ref}})

      {:noreply,
       socket
       |> assign(:generating, true)
       |> assign(:error, nil)
       |> assign(:preview_url, nil)
       |> assign(:preview_binary, nil)}
    end
  end

  def handle_event("save_image", _params, socket) do
    binary = socket.assigns.preview_binary
    prefix = socket.assigns.storage_prefix
    entity_id = socket.assigns.entity_id

    path = "#{prefix}/#{entity_id}.png"

    case Storage.store(path, binary, content_type: "image/png") do
      {:ok, _} ->
        notify_parent({:image_generated, path})
        {:noreply, assign(socket, :show, false)}

      {:error, _} ->
        {:noreply, assign(socket, :error, gettext("Failed to save image"))}
    end
  end

  def handle_event("cancel", _, socket) do
    notify_parent(:cancelled)
    {:noreply, assign(socket, :show, false)}
  end

  defp decode_data_url("data:" <> rest) do
    case String.split(rest, ";base64,", parts: 2) do
      [mime, b64] ->
        case Base.decode64(b64) do
          {:ok, binary} -> {:ok, mime, binary}
          :error -> :error
        end

      _ ->
        :error
    end
  end

  defp decode_data_url(_), do: :error
end
