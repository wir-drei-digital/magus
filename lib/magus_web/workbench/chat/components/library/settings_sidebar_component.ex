defmodule MagusWeb.ChatLive.Components.Library.SettingsSidebarComponent do
  @moduledoc """
  LiveComponent for conversation settings in the Library sidebar.

  Allows users to configure:
  - System prompt (custom instructions for the AI)
  - Sampling settings (temperature, max_tokens, top_p, top_k)

  Settings are auto-saved on change with debounce.
  """
  use MagusWeb, :live_component

  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-4">
      <div :if={@form == nil} class="text-sm text-base-content/50 text-center py-4">
        {gettext("Select a conversation to configure settings")}
      </div>
      <.form
        :if={@form != nil}
        for={@form}
        phx-change="update_settings"
        phx-target={@myself}
        phx-debounce="500"
        id="settings-form"
      >
        <%!-- System Prompt --%>
        <div class="form-control mb-4">
          <label class="label">
            <span class="label-text text-xs font-medium">{gettext("System Prompt")}</span>
          </label>
          <textarea
            name={@form[:system_prompt].name}
            class="textarea textarea-bordered textarea-sm h-24 text-sm"
            placeholder={gettext("Custom instructions for the AI...")}
            phx-debounce="500"
          >{@form[:system_prompt].value}</textarea>
          <label class="label">
            <span class="label-text-alt text-xs opacity-50">
              {gettext("Override the default system prompt")}
            </span>
          </label>
        </div>

        <%!-- Sampling Settings --%>
        <div class="space-y-4">
          <div class="text-xs font-medium text-base-content/70 mb-2">
            {gettext("Sampling Settings")}
          </div>

          <%!-- Temperature --%>
          <div class="form-control">
            <label class="label py-1">
              <span class="label-text text-xs">{gettext("Temperature")}</span>
            </label>
            <input
              type="number"
              name="sampling_settings[temperature]"
              value={@temperature}
              min="0"
              max="2"
              step="0.1"
              placeholder={gettext("Default")}
              class="input input-bordered input-sm text-sm"
              phx-debounce="500"
            />
            <span class="text-xs opacity-50 mt-1">
              {gettext(
                "How predictable vs creative (lower value => more deterministic). Recommended: 0.7–1.0"
              )}
            </span>
          </div>

          <%!-- Max Tokens --%>
          <div class="form-control">
            <label class="label py-1">
              <span class="label-text text-xs">{gettext("Max Tokens")}</span>
            </label>
            <input
              type="number"
              name="sampling_settings[max_tokens]"
              value={@max_tokens}
              min="1"
              max="128000"
              placeholder={gettext("Default")}
              class="input input-bordered input-sm text-sm"
              phx-debounce="500"
            />
            <span class="text-xs opacity-50 mt-1">
              {gettext("Limits response length. Recommended: 1000–8192")}
            </span>
          </div>

          <%!-- Top P --%>
          <div class="form-control">
            <label class="label py-1">
              <span class="label-text text-xs">{gettext("Top P")}</span>
            </label>
            <input
              type="number"
              name="sampling_settings[top_p]"
              value={@top_p}
              min="0"
              max="1"
              step="0.05"
              placeholder={gettext("Default")}
              class="input input-bordered input-sm text-sm"
              phx-debounce="500"
            />
            <span class="text-xs opacity-50 mt-1">
              {gettext("Lower = more focused responses. Recommended: 0.9–1.0")}
            </span>
          </div>

          <%!-- Top K --%>
          <div class="form-control">
            <label class="label py-1">
              <span class="label-text text-xs">{gettext("Top K")}</span>
            </label>
            <input
              type="number"
              name="sampling_settings[top_k]"
              value={@top_k}
              min="1"
              max="100"
              placeholder={gettext("Default")}
              class="input input-bordered input-sm text-sm"
              phx-debounce="500"
            />
            <span class="text-xs opacity-50 mt-1">
              {gettext("Limits word choices. Recommended: 40–100")}
            </span>
          </div>
        </div>
      </.form>

      <%!-- Reset Button --%>
      <button
        :if={@form != nil}
        type="button"
        class="btn btn-ghost btn-sm text-xs"
        phx-click="reset_settings"
        phx-target={@myself}
      >
        <.icon name="lucide-refresh-cw" class="w-4 h-4" />
        {gettext("Reset to Defaults")}
      </button>
    </div>
    """
  end

  def mount(socket) do
    {:ok,
     socket
     |> assign(:temperature, nil)
     |> assign(:max_tokens, nil)
     |> assign(:top_p, nil)
     |> assign(:top_k, nil)
     |> assign(:form, nil)}
  end

  def update(assigns, socket) do
    socket = assign(socket, assigns)

    socket =
      if socket.assigns[:conversation_id] do
        load_conversation_settings(socket)
      else
        socket
      end

    {:ok, socket}
  end

  defp load_conversation_settings(socket) do
    case Magus.Chat.get_conversation(socket.assigns.conversation_id,
           actor: socket.assigns.current_user
         ) do
      {:ok, conversation} ->
        sampling = conversation.sampling_settings || %{}

        socket
        |> assign(:system_prompt, conversation.system_prompt)
        |> assign(:temperature, get_sampling_value(sampling, "temperature"))
        |> assign(:max_tokens, get_sampling_value(sampling, "max_tokens"))
        |> assign(:top_p, get_sampling_value(sampling, "top_p"))
        |> assign(:top_k, get_sampling_value(sampling, "top_k"))
        |> assign_form(conversation)

      {:error, _} ->
        socket
    end
  end

  defp get_sampling_value(sampling, key) do
    # Handle both string and atom keys
    Map.get(sampling, key) || Map.get(sampling, String.to_atom(key))
  end

  defp assign_form(socket, conversation) do
    form =
      AshPhoenix.Form.for_update(conversation, :update_settings,
        actor: socket.assigns.current_user
      )
      |> to_form()

    assign(socket, :form, form)
  end

  def handle_event("update_settings", params, socket) do
    system_prompt = get_in(params, ["form", "system_prompt"])
    sampling_params = params["sampling_settings"] || %{}

    # Build sampling settings map, only including non-empty values
    sampling_settings =
      %{}
      |> maybe_put_float("temperature", sampling_params["temperature"])
      |> maybe_put_integer("max_tokens", sampling_params["max_tokens"])
      |> maybe_put_float("top_p", sampling_params["top_p"])
      |> maybe_put_integer("top_k", sampling_params["top_k"])

    # Convert empty map to nil
    sampling_settings = if sampling_settings == %{}, do: nil, else: sampling_settings

    attrs = %{
      system_prompt: if(system_prompt == "", do: nil, else: system_prompt),
      sampling_settings: sampling_settings
    }

    case Magus.Chat.get_conversation(socket.assigns.conversation_id,
           actor: socket.assigns.current_user
         ) do
      {:ok, conversation} ->
        case Magus.Chat.update_conversation_settings(conversation, attrs,
               actor: socket.assigns.current_user
             ) do
          {:ok, _updated} ->
            {:noreply, load_conversation_settings(socket)}

          {:error, _changeset} ->
            {:noreply, socket}
        end

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("reset_settings", _params, socket) do
    case Magus.Chat.get_conversation(socket.assigns.conversation_id,
           actor: socket.assigns.current_user
         ) do
      {:ok, conversation} ->
        case Magus.Chat.reset_conversation_settings(conversation,
               actor: socket.assigns.current_user
             ) do
          {:ok, _updated} ->
            {:noreply, load_conversation_settings(socket)}

          {:error, _} ->
            {:noreply, socket}
        end

      {:error, _} ->
        {:noreply, socket}
    end
  end

  defp maybe_put_float(map, _key, nil), do: map
  defp maybe_put_float(map, _key, ""), do: map

  defp maybe_put_float(map, key, value) when is_binary(value) do
    case Float.parse(value) do
      {float, _} -> Map.put(map, key, float)
      :error -> map
    end
  end

  defp maybe_put_float(map, key, value) when is_float(value), do: Map.put(map, key, value)
  defp maybe_put_float(map, _key, _value), do: map

  defp maybe_put_integer(map, _key, nil), do: map
  defp maybe_put_integer(map, _key, ""), do: map

  defp maybe_put_integer(map, key, value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> Map.put(map, key, int)
      :error -> map
    end
  end

  defp maybe_put_integer(map, key, value) when is_integer(value), do: Map.put(map, key, value)
  defp maybe_put_integer(map, _key, _value), do: map
end
