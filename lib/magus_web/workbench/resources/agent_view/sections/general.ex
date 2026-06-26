defmodule MagusWeb.Workbench.Resources.AgentView.Sections.General do
  @moduledoc """
  General agent settings section (identity + instructions), ported from
  AgentEditLive's edit code path. The create flow is gone — this section only
  handles existing agents passed in via the `agent` assign.

  The ProfileImageGeneratorComponent sends messages to the parent LiveView
  (AgentView), which delegates results back here via send_update/3.
  """
  use MagusWeb, :live_component

  use Gettext, backend: MagusWeb.Gettext

  alias AshPhoenix.Form
  alias MagusWeb.AgentEditHelpers

  @emoji_categories [
    {"Smileys",
     ~w(😀 😃 😄 😁 😆 😅 🤣 😂 🙂 😊 😇 🥰 😍 🤩 😘 😗 😚 😙 🥲 😋 😛 😜 🤪 😝 🤑 🤗 🤭 🤫 🤔 🫡 🤐 🤨 😐 😑 😶 🫥 😏 😒 🙄 😬 🤥 😌 😔 😪 🤤 😴 😷 🤒 🤕 🤢 🤮 🥵 🥶 🥴 😵 🤯 🤠 🥳 🥸 😎 🤓 🧐 😕 🫤 😟 🙁 😮 😯 😲 😳 🥺 🥹 😦 😧 😨 😰 😥 😢 😭 😱 😖 😣 😞 😓 😩 😫 🥱 😤 😡 😠 🤬 😈 👿 💀 ☠️ 💩 🤡 👹 👺 👻 👽 👾 🤖)},
    {"People",
     ~w(👋 🤚 🖐️ ✋ 🖖 🫱 🫲 🫳 🫴 👌 🤌 🤏 ✌️ 🤞 🫰 🤟 🤘 🤙 👈 👉 👆 🖕 👇 ☝️ 🫵 👍 👎 ✊ 👊 🤛 🤜 👏 🙌 🫶 👐 🤲 🤝 🙏 ✍️ 💅 🤳 💪 🦾 🦿 🦵 🦶 👂 🦻 👃 🧠 🫀 🫁 🦷 🦴 👀 👁️ 👅 👄 🫦)},
    {"Animals",
     ~w(🐶 🐱 🐭 🐹 🐰 🦊 🐻 🐼 🐻‍❄️ 🐨 🐯 🦁 🐮 🐷 🐸 🐵 🙈 🙉 🙊 🐒 🐔 🐧 🐦 🐤 🐣 🐥 🦆 🦅 🦉 🦇 🐺 🐗 🐴 🦄 🐝 🪱 🐛 🦋 🐌 🐞 🐜 🪰 🪲 🪳 🦟 🦗 🕷️ 🦂 🐢 🐍 🦎 🦖 🦕 🐙 🦑 🦐 🦞 🦀 🐡 🐠 🐟 🐬 🐳 🐋 🦈 🦭 🐊 🐅 🐆 🦓 🦍 🦧 🦣 🐘 🦛 🦏 🐪 🐫 🦒 🦘 🦬 🐃 🐂 🐄 🐎 🐖 🐏 🐑 🦙 🐐 🦌 🐕 🐩 🦮 🐈 🐈‍⬛)},
    {"Nature",
     ~w(🌵 🎄 🌲 🌳 🌴 🪵 🌱 🌿 ☘️ 🍀 🎍 🪴 🎋 🍃 🍂 🍁 🪺 🪹 🍄 🐚 🪸 🪨 🌾 💐 🌷 🌹 🥀 🌺 🌸 🌼 🌻 🌞 🌝 🌛 🌜 🌚 🌕 🌙 🌎 🌍 🌏 🪐 💫 ⭐ 🌟 ✨ ⚡ ☄️ 💥 🔥 🌪️ 🌈 ☀️ 🌤️ ⛅ 🌥️ ☁️ 🌧️ ⛈️ 🌩️ 🌨️ ❄️ ☃️ ⛄ 🌬️ 💨 💧 💦 🫧 🌊 🏔️)},
    {"Food",
     ~w(🍏 🍎 🍐 🍊 🍋 🍌 🍉 🍇 🍓 🫐 🍈 🍒 🍑 🥭 🍍 🥥 🥝 🍅 🍆 🥑 🥦 🥬 🥒 🌶️ 🫑 🌽 🥕 🫒 🧄 🧅 🥔 🍠 🫘 🥐 🍞 🥖 🥨 🧀 🥚 🍳 🧈 🥞 🧇 🥓 🥩 🍗 🍖 🌭 🍔 🍟 🍕 🫓 🥪 🥙 🧆 🌮 🌯 🫔 🥗 🥘 🫕 🍝 🍜 🍲 🍛 🍣 🍱 🥟 🦪 🍤 🍙 🍚 🍘 🍥 🥠 🥮 🍢 🍡 🍧 🍨 🍦 🥧 🧁 🍰 🎂 🍮 🍭 🍬 🍫 🍿 🍩 🍪 🌰 🥜 🍯 🥛 🍼 🫖 ☕ 🍵 🧃 🥤 🧋 🍶 🍺 🍻 🥂 🍷 🥃 🍸 🍹 🧉 🍾 🧊)},
    {"Activities",
     ~w(⚽ 🏀 🏈 ⚾ 🥎 🎾 🏐 🏉 🥏 🎱 🪀 🏓 🏸 🏒 🏑 🥍 🏏 🪃 🥅 ⛳ 🪁 🏹 🎣 🤿 🥊 🥋 🎽 🛹 🛼 🛷 ⛸️ 🥌 🎿 ⛷️ 🏂 🪂 🏆 🥇 🥈 🥉 🏅 🎖️ 🎪 🤹 🎭 🩰 🎨 🎬 🎤 🎧 🎼 🎹 🥁 🪘 🎷 🎺 🎸 🪕 🎻 🪗 🎲 ♟️ 🎯 🎳 🎮 🕹️ 🧩)},
    {"Objects",
     ~w(⌚ 📱 💻 ⌨️ 🖥️ 🖨️ 🖱️ 💽 💾 💿 📀 📷 📸 📹 🎥 📞 ☎️ 📺 📻 🎙️ 🎚️ 🎛️ ⏰ 🕰️ ⌛ ⏳ 📡 🔋 🔌 💡 🔦 🕯️ 💰 💳 💎 ⚖️ 🧰 🔧 🔨 🛠️ ⛏️ 🔩 ⚙️ 🔫 💣 🔪 🗡️ ⚔️ 🛡️ 🔮 📿 🧿 💈 ⚗️ 🔭 🔬 💊 💉 🧬 🦠 🧪 🌡️ 🧹 🧻 🚽 🧼 🛎️ 🔑 🗝️ 🚪 🧸 🖼️ 🛍️ 🎁 🎈 🎀 🎊 🎉 🏮 ✉️ 📦 📋 📁 📂 📰 📓 📕 📗 📘 📙 📚 📖 🔖 📎 📐 📏 📌 📍 ✂️ 🖊️ ✏️ 🔍 🔎 🔒 🔓)},
    {"Symbols",
     ~w(❤️ 🧡 💛 💚 💙 💜 🖤 🤍 🤎 💔 ❤️‍🔥 ❣️ 💕 💞 💓 💗 💖 💘 💝 ☮️ ✝️ ☪️ 🕉️ ☸️ ✡️ ☯️ 🆔 ⚛️ ☢️ ☣️ ✴️ 💮 ❌ ⭕ 🛑 ⛔ 🚫 💯 ♨️ ❗ ❓ ‼️ ⁉️ ⚠️ ♻️ ✅ ❎ 🌐 💠 ♠️ ♣️ ♥️ ♦️ 🃏 🎴 🔴 🟠 🟡 🟢 🔵 🟣 ⚫ ⚪ 🟤 🔺 🔻 🔸 🔹 🔶 🔷 ▪️ ▫️ 🔈 🔉 🔊 🔔 🔕 💬 💭 ♾️)},
    {"Flags", ~w(🏁 🚩 🎌 🏴 🏳️ 🏳️‍🌈 🏴‍☠️ 🇦🇹 🇦🇺 🇧🇪 🇧🇷 🇨🇦 🇨🇭 🇨🇳 🇩🇪 🇩🇰 🇪🇸 🇫🇮 🇫🇷 🇬🇧 🇬🇷 🇮🇳 🇮🇪 🇮🇱 🇮🇹 🇯🇵 🇰🇷 🇲🇽 🇳🇱 🇳🇴 🇳🇿 🇵🇱 🇵🇹 🇷🇺 🇸🇪 🇹🇷 🇺🇦 🇺🇸 🇿🇦)}
  ]

  @impl true
  def update(%{agent: agent, current_user: current_user} = assigns, socket) do
    form = Form.for_update(agent, :update, actor: current_user) |> to_form()

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:form, form)
     |> assign(:generated_image_path, agent.image_path)
     |> assign(:agent_image_url, AgentEditHelpers.agent_image_url(agent.image_path))
     |> assign(:icon_mode, if(agent.image_path, do: :image, else: :emoji))
     |> assign(:show_image_gen, false)
     |> assign(:emoji_categories, @emoji_categories)}
  end

  # Called by AgentView when the image generator produces a result
  def update(%{image_gen_result: path}, socket) do
    {:ok,
     socket
     |> assign(:generated_image_path, path)
     |> assign(:agent_image_url, AgentEditHelpers.agent_image_url(path))
     |> assign(:icon_mode, :image)
     |> assign(:show_image_gen, false)}
  end

  def update(%{image_gen_cancelled: true}, socket) do
    {:ok, socket}
  end

  def update(%{show_image_gen: show}, socket) do
    {:ok, assign(socket, :show_image_gen, show)}
  end

  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div data-section="general" class="p-4">
      <.form for={@form} phx-submit="save" phx-change="validate" phx-target={@myself}>
        <div class="space-y-6">
          <.content_card title={gettext("Identity")} icon="lucide-user">
            <div class="space-y-4">
              <div class="flex gap-4">
                <div class="flex flex-col items-center gap-1.5">
                  <%= if @icon_mode == :image do %>
                    <div class="w-16 h-16 rounded-lg bg-base-200 flex items-center justify-center overflow-hidden border border-base-300">
                      <img
                        :if={@agent_image_url}
                        src={@agent_image_url}
                        class="w-full h-full object-cover"
                      />
                      <.icon
                        :if={!@agent_image_url}
                        name="lucide-image"
                        class="w-8 h-8 text-base-content/20"
                      />
                    </div>
                    <button
                      type="button"
                      phx-click="open_image_gen"
                      phx-target={@myself}
                      class="btn btn-xs btn-ghost gap-1"
                    >
                      <.icon name="lucide-wand-2" class="w-3 h-3" />
                      {if @agent_image_url, do: gettext("Change"), else: gettext("Generate")}
                    </button>
                  <% else %>
                    <div class="dropdown">
                      <div
                        tabindex="0"
                        role="button"
                        class="w-16 h-16 rounded-lg bg-base-200 flex items-center justify-center border border-base-300 cursor-pointer hover:border-primary transition-colors"
                      >
                        <span class="text-3xl">
                          {Form.value(@form.source, :icon) || "🤖"}
                        </span>
                      </div>
                      <div
                        tabindex="0"
                        class="dropdown-content z-20 bg-base-200 rounded-box shadow-lg p-2 w-72 mt-1 max-h-64 overflow-y-auto"
                      >
                        <div :for={{category, emojis} <- @emoji_categories}>
                          <div class="text-xs text-base-content/50 font-medium px-1 pt-2 pb-1 sticky top-0 bg-base-200">
                            {category}
                          </div>
                          <div class="grid grid-cols-8 gap-0.5">
                            <button
                              :for={emoji <- emojis}
                              type="button"
                              phx-click="select_emoji"
                              phx-value-emoji={emoji}
                              phx-target={@myself}
                              class="btn btn-ghost btn-sm text-xl p-0 h-8 w-8 min-h-0"
                            >
                              {emoji}
                            </button>
                          </div>
                        </div>
                      </div>
                    </div>
                  <% end %>

                  <div class="flex bg-base-200 rounded-lg p-0.5">
                    <button
                      type="button"
                      phx-click="set_icon_mode"
                      phx-value-mode="emoji"
                      phx-target={@myself}
                      class={"btn btn-xs min-h-0 h-6 #{if @icon_mode == :emoji, do: "btn-primary", else: "btn-ghost"}"}
                    >
                      {gettext("Emoji")}
                    </button>
                    <button
                      type="button"
                      phx-click="set_icon_mode"
                      phx-value-mode="image"
                      phx-target={@myself}
                      class={"btn btn-xs min-h-0 h-6 #{if @icon_mode == :image, do: "btn-primary", else: "btn-ghost"}"}
                    >
                      {gettext("Image")}
                    </button>
                  </div>
                </div>

                <div class="flex-1 space-y-3">
                  <input
                    type="hidden"
                    name="form[icon]"
                    value={Form.value(@form.source, :icon)}
                  />
                  <.input
                    field={@form[:name]}
                    type="text"
                    label={gettext("Name")}
                    placeholder={gettext("My Agent")}
                    required
                  />
                  <.input
                    field={@form[:description]}
                    type="text"
                    label={gettext("Description")}
                    placeholder={gettext("What does this agent do?")}
                  />
                </div>
              </div>
            </div>
          </.content_card>

          <.content_card title={gettext("Instructions")} icon="lucide-file-text">
            <.input
              field={@form[:instructions]}
              type="textarea"
              label={gettext("System Prompt")}
              placeholder={gettext("You are a helpful assistant that...")}
              class="textarea h-40 font-mono text-sm"
            />
            <p class="text-xs text-base-content/50 mt-2">
              {gettext(
                "These instructions define the agent's personality and behavior. They are prepended to every conversation."
              )}
            </p>
          </.content_card>

          <div class="flex justify-end pt-2 pb-4">
            <button type="submit" class="btn btn-primary">
              {gettext("Save Changes")}
            </button>
          </div>
        </div>
      </.form>

      <.live_component
        module={MagusWeb.ProfileImageGeneratorComponent}
        id={"agent-profile-image-gen-#{@id}"}
        show={@show_image_gen}
        storage_prefix="agent_images"
        entity_id={@agent.id}
        current_image_url={@agent_image_url}
      />
    </div>
    """
  end

  @impl true
  def handle_event("validate", %{"form" => params}, socket) do
    form = Form.validate(socket.assigns.form.source, params)
    {:noreply, assign(socket, :form, to_form(form))}
  end

  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("save", %{"form" => params}, socket) when is_map(params) do
    params =
      params
      |> Map.put("image_path", socket.assigns.generated_image_path)
      |> clean_empty_ids(["chat_mode"])

    case Form.submit(socket.assigns.form.source, params: params) do
      {:ok, _agent} ->
        {:noreply, put_flash(socket, :info, gettext("Agent saved successfully"))}

      {:error, form} ->
        {:noreply, assign(socket, :form, to_form(form))}
    end
  end

  def handle_event("save", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("set_icon_mode", %{"mode" => "emoji"}, socket) do
    {:noreply,
     socket
     |> assign(:icon_mode, :emoji)
     |> assign(:generated_image_path, nil)
     |> assign(:agent_image_url, nil)}
  end

  def handle_event("set_icon_mode", %{"mode" => "image"}, socket) do
    {:noreply, assign(socket, :icon_mode, :image)}
  end

  def handle_event("select_emoji", %{"emoji" => emoji}, socket) do
    form = Form.validate(socket.assigns.form.source, %{"icon" => emoji})
    {:noreply, assign(socket, :form, to_form(form))}
  end

  def handle_event("open_image_gen", _, socket) do
    {:noreply, assign(socket, :show_image_gen, true)}
  end

  defp clean_empty_ids(params, keys) do
    Enum.reduce(keys, params, fn key, acc ->
      case Map.get(acc, key) do
        "" -> Map.put(acc, key, nil)
        _ -> acc
      end
    end)
  end
end
