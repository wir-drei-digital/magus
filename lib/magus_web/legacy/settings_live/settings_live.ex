defmodule MagusWeb.SettingsLive do
  @moduledoc """
  User settings page for managing profile, email, password, avatar, language, and model preferences.
  """
  use MagusWeb, :live_view

  alias MagusWeb.Layouts
  alias MagusWeb.SettingsLive.DeleteAccountModalComponent
  alias Magus.Accounts
  alias Magus.Chat
  alias Magus.Files
  alias Magus.Files.Storage

  on_mount {MagusWeb.LiveUserAuth, :live_user_required}

  @max_avatar_size 5_000_000
  @accepted_avatar_types ~w(.jpg .jpeg .png .gif .webp)

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    {:ok, init_assigns(socket, user)}
  end

  @doc false
  def init_assigns(socket, user) do
    {:ok, models} = Chat.list_active_models(authorize?: false)
    {:ok, image_models} = Chat.list_image_generation_models(authorize?: false)
    {:ok, video_models} = Chat.list_video_generation_models(authorize?: false)

    storage_usage = calculate_storage_usage(user.id)

    socket
    |> assign(:page_title, gettext("Settings"))
    |> assign(:user, user)
    |> assign(:models, models)
    |> assign(:image_models, image_models)
    |> assign(:video_models, video_models)
    |> assign(:storage_usage, storage_usage)
    |> assign(:timezone_form, to_form(%{"timezone" => user.timezone || "UTC"}, as: "timezone"))
    |> assign(:timezone_locked, timezone_locked?(user))
    |> assign(:timezone_days_remaining, timezone_days_remaining(user))
    |> assign(
      :autoscroll_enabled,
      Map.get(user.ui_preferences || %{}, "autoscroll_enabled", true)
    )
    |> assign(
      :tabs_enabled,
      Map.get(user.ui_preferences || %{}, "tabs_enabled", false)
    )
    |> assign(:has_password, user.hashed_password != nil)
    |> assign_profile_form(user)
    |> assign_email_form()
    |> assign_password_form()
    |> assign(:show_avatar_gen, false)
    |> assign(:profile_gen_ref, nil)
    |> allow_upload(:avatar,
      accept: @accepted_avatar_types,
      max_entries: 1,
      max_file_size: @max_avatar_size,
      auto_upload: true
    )
    |> assign(:delete_modal_open?, false)
    |> assign(:delete_preflight, nil)
  end

  @impl true
  def handle_params(params, _uri, socket) do
    current_path =
      case socket.assigns.live_action do
        :profile -> "/settings"
        :preferences -> "/settings/preferences"
        :storage -> "/settings/storage"
        :data -> "/settings/data"
      end

    socket =
      socket
      |> assign(:current_path, current_path)
      |> assign(:nav_items, settings_nav_items(current_path, socket.assigns.user))
      |> apply_action(socket.assigns.live_action, params)

    {:noreply, socket}
  end

  defp apply_action(socket, :data, _params) do
    socket
    |> assign(:page_title, gettext("My Data"))
    |> assign(:delete_modal_open?, false)
    |> assign(:delete_preflight, nil)
  end

  defp apply_action(socket, _other, _params), do: socket

  defp assign_profile_form(socket, user) do
    form =
      user
      |> AshPhoenix.Form.for_update(:update_settings,
        domain: Accounts,
        actor: user
      )
      |> to_form()

    assign(socket, :profile_form, form)
  end

  defp assign_email_form(socket) do
    form = to_form(%{"new_email" => ""}, as: "email_change")
    assign(socket, :email_form, form)
  end

  defp assign_password_form(socket) do
    form =
      to_form(
        %{
          "current_password" => "",
          "password" => "",
          "password_confirmation" => ""
        },
        as: "password_change"
      )

    assign(socket, :password_form, form)
  end

  defp calculate_storage_usage(user_id) do
    case Files.my_files(actor: %{id: user_id}) do
      {:ok, files} ->
        total_bytes = Enum.reduce(files, 0, fn f, acc -> acc + (f.file_size || 0) end)
        file_count = length(files)

        %{
          total_bytes: total_bytes,
          file_count: file_count,
          formatted: format_bytes(total_bytes)
        }

      {:error, _} ->
        %{total_bytes: 0, file_count: 0, formatted: "0 B"}
    end
  end

  defp format_bytes(bytes), do: MagusWeb.Formatters.format_bytes(bytes)

  # -- Events: Profile --

  @impl true
  def handle_event("validate_profile", %{"form" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.profile_form, params)
    {:noreply, assign(socket, :profile_form, form)}
  end

  @impl true
  def handle_event("save_profile", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.profile_form, params: params) do
      {:ok, user} ->
        Gettext.put_locale(MagusWeb.Gettext, to_string(user.language))

        {:noreply,
         socket
         |> put_flash(:info, gettext("Profile updated successfully"))
         |> assign(:user, user)
         |> assign(:current_user, user)
         |> assign_profile_form(user)}

      {:error, form} ->
        {:noreply, assign(socket, :profile_form, form)}
    end
  end

  @impl true
  def handle_event(
        "request_email_change",
        %{"email_change" => %{"new_email" => new_email}},
        socket
      ) do
    user = socket.assigns.user

    case Accounts.request_email_change(user, new_email, actor: user) do
      {:ok, updated_user} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Confirmation email sent to %{email}", email: new_email))
         |> assign(:user, updated_user)
         |> assign_email_form()}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("Could not request email change. The email may already be in use.")
         )}
    end
  end

  @impl true
  def handle_event("change_password", %{"password_change" => params}, socket) do
    user = socket.assigns.user

    result =
      if socket.assigns.has_password do
        Accounts.change_user_password(user, params, actor: user)
      else
        Accounts.set_user_password(user, params, actor: user)
      end

    case result do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Password changed successfully"))
         |> assign(:has_password, true)
         |> assign_password_form()}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Failed to change password. Check your current password."))
         |> assign_password_form()}
    end
  end

  # -- Events: Avatar --

  @impl true
  def handle_event("validate_avatar", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("upload_avatar", _params, socket) do
    user = socket.assigns.user

    uploaded_files =
      consume_uploaded_entries(socket, :avatar, fn %{path: path}, entry ->
        content = File.read!(path)
        ext = Path.extname(entry.client_name) |> String.downcase()
        avatar_path = "avatars/#{user.id}#{ext}"

        case Storage.store(avatar_path, content) do
          {:ok, _} -> {:ok, avatar_path}
          {:error, reason} -> {:error, reason}
        end
      end)

    case uploaded_files do
      [avatar_path] when is_binary(avatar_path) ->
        if user.avatar_path do
          Storage.delete(user.avatar_path)
        end

        case Accounts.update_avatar(user, avatar_path, actor: user) do
          {:ok, updated_user} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Avatar updated"))
             |> assign(:user, updated_user)
             |> assign(:current_user, updated_user)}

          {:error, changeset} ->
            require Logger
            Logger.error("Failed to update avatar: #{inspect(changeset)}")
            {:noreply, put_flash(socket, :error, gettext("Failed to update avatar"))}
        end

      [] ->
        {:noreply, put_flash(socket, :error, gettext("No file selected"))}

      other ->
        require Logger
        Logger.error("Unexpected upload result: #{inspect(other)}")
        {:noreply, put_flash(socket, :error, gettext("Upload failed"))}
    end
  end

  @impl true
  def handle_event("delete_avatar", _params, socket) do
    user = socket.assigns.user

    case Accounts.delete_avatar(user, actor: user) do
      {:ok, updated_user} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Avatar removed"))
         |> assign(:user, updated_user)
         |> assign(:current_user, updated_user)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to remove avatar"))}
    end
  end

  @impl true
  def handle_event("open_avatar_gen", _, socket) do
    {:noreply, assign(socket, :show_avatar_gen, true)}
  end

  # -- Events: Models --

  @impl true
  def handle_event("select_default_model", %{"model_id" => model_id}, socket) do
    user = socket.assigns.user

    case Accounts.select_model(user.id, model_id, actor: user) do
      {:ok, updated_user} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Default model updated"))
         |> assign(:user, updated_user)
         |> assign(:current_user, updated_user)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update default model"))}
    end
  end

  @impl true
  def handle_event("select_default_image_model", %{"model_id" => model_id}, socket) do
    user = socket.assigns.user

    case Accounts.select_image_model(user.id, model_id, actor: user) do
      {:ok, updated_user} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Default image model updated"))
         |> assign(:user, updated_user)
         |> assign(:current_user, updated_user)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update default image model"))}
    end
  end

  @impl true
  def handle_event("select_default_video_model", %{"model_id" => model_id}, socket) do
    user = socket.assigns.user

    case Accounts.select_video_model(user.id, model_id, actor: user) do
      {:ok, updated_user} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Default video model updated"))
         |> assign(:user, updated_user)
         |> assign(:current_user, updated_user)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update default video model"))}
    end
  end

  # -- Events: Timezone --

  @impl true
  def handle_event("save_timezone", %{"timezone" => %{"timezone" => timezone}}, socket) do
    user = socket.assigns.user

    case Accounts.update_timezone(user, timezone, actor: user) do
      {:ok, updated_user} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Timezone updated"))
         |> assign(:user, updated_user)
         |> assign(:current_user, updated_user)
         |> assign(
           :timezone_form,
           to_form(%{"timezone" => updated_user.timezone}, as: "timezone")
         )
         |> assign(:timezone_locked, timezone_locked?(updated_user))
         |> assign(:timezone_days_remaining, timezone_days_remaining(updated_user))}

      {:error, %Ash.Error.Invalid{errors: [%{message: msg} | _]}} when is_binary(msg) ->
        {:noreply, put_flash(socket, :error, msg)}

      {:error, _} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Failed to update timezone. Check the format or try again later.")
         )}
    end
  end

  # -- Events: Preferences --

  @impl true
  def handle_event("toggle_autoscroll", _params, socket) do
    new_value = !socket.assigns.autoscroll_enabled
    user = socket.assigns.user
    current_prefs = user.ui_preferences || %{}
    updated_prefs = Map.put(current_prefs, "autoscroll_enabled", new_value)

    Task.start(fn ->
      Accounts.update_ui_preferences(user, updated_prefs, actor: user)
    end)

    {:noreply,
     socket
     |> assign(:autoscroll_enabled, new_value)
     |> put_flash(
       :info,
       if(new_value, do: gettext("Autoscroll enabled"), else: gettext("Autoscroll disabled"))
     )}
  end

  def handle_event("select_context_strategy", %{"context_strategy" => raw}, socket) do
    user = socket.assigns.user
    strategy = parse_context_strategy(raw)

    case Accounts.update_user_settings(user, %{context_strategy: strategy}, actor: user) do
      {:ok, updated_user} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Default context strategy updated"))
         |> assign(:user, updated_user)
         |> assign(:current_user, updated_user)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update context strategy"))}
    end
  end

  def handle_event("toggle_tabs_enabled", _params, socket) do
    new_value = !socket.assigns.tabs_enabled
    user = socket.assigns.user
    current_prefs = user.ui_preferences || %{}
    updated_prefs = Map.put(current_prefs, "tabs_enabled", new_value)

    Task.start(fn ->
      Accounts.update_ui_preferences(user, updated_prefs, actor: user)
    end)

    Phoenix.PubSub.broadcast(
      Magus.PubSub,
      MagusWeb.Workbench.Signals.workbench_user_topic(user.id),
      {:ui_preferences_changed, updated_prefs}
    )

    {:noreply,
     socket
     |> assign(:tabs_enabled, new_value)
     |> put_flash(
       :info,
       if(new_value, do: gettext("Tabs enabled"), else: gettext("Tabs disabled"))
     )}
  end

  # -- Events: My Data --

  @impl true
  def handle_event("open_delete_account_modal", _params, socket) do
    preflight = Magus.Accounts.AccountDeletion.preflight(socket.assigns.user)

    {:noreply,
     socket
     |> assign(:delete_modal_open?, true)
     |> assign(:delete_preflight, preflight)}
  end

  @impl true
  def handle_event("close_delete_account_modal", _params, socket) do
    {:noreply, assign(socket, :delete_modal_open?, false)}
  end

  # -- Info: Avatar Generation --

  @impl true
  def handle_info(
        {MagusWeb.ProfileImageGeneratorComponent, {:task_started, ref}},
        socket
      ) do
    {:noreply, assign(socket, :profile_gen_ref, ref)}
  end

  def handle_info({ref, result}, %{assigns: %{profile_gen_ref: ref}} = socket)
      when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    send_update(MagusWeb.ProfileImageGeneratorComponent,
      id: "avatar-profile-image-gen",
      task_result: result
    )

    {:noreply, assign(socket, :profile_gen_ref, nil)}
  end

  def handle_info(
        {MagusWeb.ProfileImageGeneratorComponent, {:image_generated, path}},
        socket
      ) do
    user = socket.assigns.user

    if user.avatar_path, do: Storage.delete(user.avatar_path)

    case Accounts.update_avatar(user, path, actor: user) do
      {:ok, updated_user} ->
        {:noreply,
         socket
         |> assign(:show_avatar_gen, false)
         |> assign(:user, updated_user)
         |> assign(:current_user, updated_user)
         |> put_flash(:info, gettext("Avatar generated and saved"))}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(:show_avatar_gen, false)
         |> put_flash(:error, gettext("Failed to save generated avatar"))}
    end
  end

  def handle_info({MagusWeb.ProfileImageGeneratorComponent, :cancelled}, socket) do
    {:noreply, assign(socket, :show_avatar_gen, false)}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, socket) do
    {:noreply, socket}
  end

  # -- Render --

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} bg_class="bg-spectral">
      <:notification_bell>
        <.live_component
          module={MagusWeb.NotificationBellComponent}
          id="notification-bell"
          current_user={@current_user}
          unread_count={@unread_count}
        />
      </:notification_bell>

      <div class="container mx-auto max-w-4xl py-8 px-4">
        <h1 class="text-2xl font-bold mb-6">{gettext("Settings")}</h1>

        <.page_with_sidebar_nav nav_items={@nav_items}>
          <div class="space-y-6">
            <%= case @live_action do %>
              <% :profile -> %>
                <.render_profile_section
                  user={@user}
                  uploads={@uploads}
                  show_avatar_gen={@show_avatar_gen}
                  profile_form={@profile_form}
                  email_form={@email_form}
                  password_form={@password_form}
                  has_password={@has_password}
                />
              <% :preferences -> %>
                <.render_preferences_section
                  user={@user}
                  models={@models}
                  image_models={@image_models}
                  video_models={@video_models}
                  timezone_form={@timezone_form}
                  timezone_locked={@timezone_locked}
                  timezone_days_remaining={@timezone_days_remaining}
                  autoscroll_enabled={@autoscroll_enabled}
                  tabs_enabled={@tabs_enabled}
                />
              <% :storage -> %>
                <.render_storage_section storage_usage={@storage_usage} />
              <% :data -> %>
                <.render_data_section
                  current_user={@current_user}
                  delete_modal_open?={@delete_modal_open?}
                  delete_preflight={@delete_preflight}
                />
            <% end %>
          </div>
        </.page_with_sidebar_nav>
      </div>
    </Layouts.app>
    """
  end

  # -- Section Components --

  attr :user, :map, required: true
  attr :uploads, :map, required: true
  attr :show_avatar_gen, :boolean, required: true
  attr :profile_form, :any, required: true
  attr :email_form, :any, required: true
  attr :password_form, :any, required: true
  attr :has_password, :boolean, required: true

  def render_profile_section(assigns) do
    ~H"""
    <.content_card title={gettext("Profile")} icon="lucide-user">
      <div class="flex items-start gap-6">
        <div class="flex flex-col items-center gap-2">
          <.user_avatar user={@user} size="lg" />
          <.avatar_upload uploads={@uploads} user={@user} />
          <button
            type="button"
            phx-click="open_avatar_gen"
            class="btn btn-xs btn-ghost gap-1"
          >
            <.icon name="lucide-wand-2" class="w-3 h-3" />
            {gettext("AI")}
          </button>
        </div>

        <.live_component
          module={MagusWeb.ProfileImageGeneratorComponent}
          id="avatar-profile-image-gen"
          show={@show_avatar_gen}
          storage_prefix="avatars"
          entity_id={@user.id}
        />

        <div class="flex-1">
          <.form
            for={@profile_form}
            phx-change="validate_profile"
            phx-submit="save_profile"
            class="space-y-4"
          >
            <.input
              field={@profile_form[:name]}
              label={gettext("Name")}
              placeholder={gettext("Your name")}
            />

            <.input
              field={@profile_form[:display_name]}
              label={gettext("Display Name")}
              placeholder={gettext("Your name")}
            />

            <.input
              field={@profile_form[:language]}
              type="select"
              label={gettext("Language")}
              options={[{"English", "en"}, {"Deutsch", "de"}]}
            />

            <button type="submit" class="btn btn-primary">
              {gettext("Save Profile")}
            </button>
          </.form>
        </div>
      </div>
    </.content_card>

    <.content_card title={gettext("Email")} icon="lucide-mail">
      <div class="space-y-4">
        <p class="text-sm text-base-content/70">
          {gettext("Current email:")} <span class="font-medium">{@user.email}</span>
        </p>

        <div :if={@user.pending_email} class="alert alert-info">
          <.icon name="lucide-info" class="w-5 h-5" />
          <span>
            {gettext("Pending email change to: %{email}. Check your inbox.",
              email: @user.pending_email
            )}
          </span>
        </div>

        <.form for={@email_form} phx-submit="request_email_change" class="space-y-4">
          <.input
            field={@email_form[:new_email]}
            type="email"
            label={gettext("New Email")}
            placeholder="your-new@email.com"
          />
          <button type="submit" class="btn btn-secondary">
            {gettext("Change Email")}
          </button>
        </.form>
      </div>
    </.content_card>

    <.content_card title={gettext("Password")} icon="lucide-key">
      <.form for={@password_form} phx-submit="change_password" class="space-y-4 max-w-md">
        <.input
          :if={@has_password}
          field={@password_form[:current_password]}
          type="password"
          label={gettext("Current Password")}
          autocomplete="current-password"
        />
        <.input
          field={@password_form[:password]}
          type="password"
          label={gettext("New Password")}
          autocomplete="new-password"
        />
        <.input
          field={@password_form[:password_confirmation]}
          type="password"
          label={gettext("Confirm New Password")}
          autocomplete="new-password"
        />
        <button type="submit" class="btn btn-secondary">
          {if @has_password, do: gettext("Change Password"), else: gettext("Set Password")}
        </button>
      </.form>
    </.content_card>
    """
  end

  attr :user, :map, required: true
  attr :models, :list, required: true
  attr :image_models, :list, required: true
  attr :video_models, :list, required: true
  attr :timezone_form, :any, required: true
  attr :timezone_locked, :boolean, required: true
  attr :timezone_days_remaining, :integer, required: true
  attr :autoscroll_enabled, :boolean, required: true
  attr :tabs_enabled, :boolean, required: true

  def render_preferences_section(assigns) do
    ~H"""
    <.content_card title={gettext("Default Models")} icon="lucide-cpu">
      <p class="text-sm text-base-content/60 mb-4">
        {gettext("When set to Auto, the system automatically picks the best model for each request.")}
      </p>
      <div class="space-y-4">
        <.form for={%{}} phx-change="select_default_model">
          <.input
            type="select"
            name="model_id"
            label={gettext("Default Chat Model")}
            value={@user.selected_model_id}
            prompt={gettext("Auto (recommended)")}
            options={Enum.map(@models, &{&1.name, &1.id})}
          />
        </.form>

        <.form for={%{}} phx-change="select_default_image_model">
          <.input
            type="select"
            name="model_id"
            label={gettext("Default Image Generation Model")}
            value={@user.selected_image_model_id}
            prompt={gettext("Auto (recommended)")}
            options={Enum.map(@image_models, &{&1.name, &1.id})}
          />
        </.form>

        <.form for={%{}} phx-change="select_default_video_model">
          <.input
            type="select"
            name="model_id"
            label={gettext("Default Video Generation Model")}
            value={@user.selected_video_model_id}
            prompt={gettext("Auto (recommended)")}
            options={Enum.map(@video_models, &{&1.name, &1.id})}
          />
        </.form>
      </div>
    </.content_card>

    <.content_card title={gettext("Timezone")} icon="lucide-globe">
      <.form for={@timezone_form} phx-submit="save_timezone" class="space-y-4 max-w-md">
        <.input
          field={@timezone_form[:timezone]}
          type="text"
          label={gettext("Timezone (IANA format)")}
          placeholder="America/New_York"
          disabled={@timezone_locked}
        />
        <p :if={@timezone_locked} class="text-sm text-warning">
          {gettext("You can change your timezone again in %{days} days.",
            days: @timezone_days_remaining
          )}
        </p>
        <button type="submit" class="btn btn-secondary" disabled={@timezone_locked}>
          {gettext("Update Timezone")}
        </button>
      </.form>
    </.content_card>

    <.content_card title={gettext("Chat")} icon="lucide-message-square">
      <div class="space-y-6">
        <div class="flex items-center justify-between max-w-md">
          <div>
            <p class="font-medium">{gettext("Autoscroll during streaming")}</p>
            <p class="text-sm text-base-content/70">
              {gettext("Automatically scroll to the latest message while the AI is responding")}
            </p>
          </div>
          <input
            type="checkbox"
            class="toggle toggle-primary"
            checked={@autoscroll_enabled}
            phx-click="toggle_autoscroll"
          />
        </div>

        <div class="max-w-md">
          <.form
            for={%{}}
            id="context-strategy-form"
            phx-change="select_context_strategy"
            data-role="settings-context-strategy"
          >
            <.input
              type="select"
              name="context_strategy"
              label={gettext("Default context strategy")}
              value={@user.context_strategy && to_string(@user.context_strategy)}
              prompt={gettext("Use default (Rolling)")}
              options={[
                {gettext("Rolling"), "rolling"},
                {gettext("Compact"), "compact"}
              ]}
            />
          </.form>
          <p class="text-sm text-base-content/70 mt-1">
            {gettext(
              "Rolling keeps recent turns in full; Compact summarizes older turns to fit longer conversations."
            )}
          </p>
        </div>
      </div>
    </.content_card>

    <.content_card title={gettext("Layout")} icon="lucide-layout">
      <div class="flex items-center justify-between max-w-md">
        <div>
          <p class="font-medium">{gettext("Show tabs")}</p>
          <p class="text-sm text-base-content/70">
            {gettext("Display the tab bar above the main panel for switching between open items")}
          </p>
        </div>
        <input
          type="checkbox"
          class="toggle toggle-primary"
          checked={@tabs_enabled}
          phx-click="toggle_tabs_enabled"
        />
      </div>
    </.content_card>
    """
  end

  attr :storage_usage, :map, required: true

  def render_storage_section(assigns) do
    ~H"""
    <.content_card title={gettext("Storage")} icon="lucide-database">
      <div class="space-y-2">
        <p class="text-sm text-base-content/70">
          {gettext("You have %{count} files using %{size} of storage.",
            count: @storage_usage.file_count,
            size: @storage_usage.formatted
          )}
        </p>
        <.link navigate="/chat" class="link link-primary text-sm">
          {gettext("Manage files in Chat")}
        </.link>
      </div>
    </.content_card>
    """
  end

  attr :current_user, :map, required: true
  attr :delete_modal_open?, :boolean, required: true
  attr :delete_preflight, :any, required: true

  def render_data_section(assigns) do
    ~H"""
    <.content_card title={gettext("Export your data")} icon="lucide-download">
      <p class="text-sm text-base-content/70 mb-4">
        {gettext(
          "Download a JSON file containing every conversation, brain, memory, custom agent, prompt, and draft Magus has stored for you. File contents are not included: download individual files from the file browser."
        )}
      </p>
      <p class="text-sm text-base-content/70 mb-4">
        {gettext(
          "The export includes disabled and hidden messages too: anything we hold about you is in there."
        )}
      </p>
      <.link href={~p"/settings/data/export"} class="btn btn-primary">
        {gettext("Download magus-export.json")}
      </.link>
    </.content_card>

    <.content_card title={gettext("Delete your account")} icon="lucide-trash-2">
      <p class="text-sm text-base-content/70 mb-2">
        {gettext("Permanently delete your account and all associated data. This cannot be undone.")}
      </p>
      <p class="text-sm text-base-content/70 mb-4">
        {gettext(
          "Aggregated usage statistics (token counts, costs) are kept with your account reference removed, for billing and statistics."
        )}
      </p>
      <button type="button" phx-click="open_delete_account_modal" class="btn btn-error">
        {gettext("Delete my account")}
      </button>
    </.content_card>

    <.live_component
      :if={@delete_modal_open?}
      module={DeleteAccountModalComponent}
      id="delete-account-modal"
      current_user={@current_user}
      preflight={@delete_preflight}
    />
    """
  end

  # -- Shared Helpers --

  attr :uploads, :map, required: true
  attr :user, :map, required: true

  defp avatar_upload(assigns) do
    ~H"""
    <.form
      for={%{}}
      phx-change="validate_avatar"
      phx-submit="upload_avatar"
      class="flex flex-col items-center gap-2"
    >
      <.live_file_input upload={@uploads.avatar} class="hidden" />
      <label
        for={@uploads.avatar.ref}
        class="btn btn-sm btn-ghost"
      >
        <.icon name="lucide-camera" class="w-4 h-4" />
        {gettext("Change")}
      </label>

      <div :for={entry <- @uploads.avatar.entries} class="text-xs text-base-content/70">
        {gettext("Uploading: %{progress}%", progress: entry.progress)}
      </div>

      <div :for={entry <- @uploads.avatar.entries}>
        <button
          type="submit"
          class="btn btn-sm btn-primary"
        >
          {gettext("Save")}
        </button>
      </div>

      <button
        :if={@user.avatar_path}
        type="button"
        phx-click="delete_avatar"
        class="btn btn-sm btn-ghost text-error"
      >
        {gettext("Remove")}
      </button>
    </.form>
    """
  end

  # Map the select value to the User.context_strategy attribute. "" (the prompt /
  # "Use default" option) clears to nil; anything other than the known strategies
  # also clears, avoiding String.to_atom on user input (atom exhaustion).
  defp parse_context_strategy("rolling"), do: :rolling
  defp parse_context_strategy("compact"), do: :compact
  defp parse_context_strategy(_), do: nil

  defp timezone_locked?(user) do
    case user.last_timezone_change_at do
      nil -> false
      last_change -> DateTime.diff(DateTime.utc_now(), last_change, :day) < 30
    end
  end

  defp timezone_days_remaining(user) do
    case user.last_timezone_change_at do
      nil -> 0
      last_change -> max(0, 30 - DateTime.diff(DateTime.utc_now(), last_change, :day))
    end
  end

  @doc false
  def settings_nav_items(current_path, user) do
    base_items = [
      %{
        label: gettext("Profile"),
        icon: "lucide-user",
        href: "/settings",
        active?: current_path == "/settings"
      },
      %{
        label: gettext("Preferences"),
        icon: "lucide-sliders",
        href: "/settings/preferences",
        active?: current_path == "/settings/preferences"
      },
      %{
        label: gettext("Storage"),
        icon: "lucide-database",
        href: "/settings/storage",
        active?: current_path == "/settings/storage"
      },
      %{
        label: gettext("My Data"),
        icon: "lucide-shield",
        href: "/settings/data",
        active?: current_path == "/settings/data"
      },
      %{
        label: gettext("Connected Sources"),
        icon: "lucide-folder-sync",
        href: "/settings/knowledge",
        active?: current_path == "/settings/knowledge"
      },
      %{
        label: gettext("Seats"),
        icon: "lucide-users",
        href: "/settings/seats",
        active?: current_path == "/settings/seats"
      }
    ]

    admin_items =
      if user.is_admin do
        [
          %{
            label: gettext("Subscription"),
            icon: "lucide-credit-card",
            href: "/settings/subscription",
            active?: current_path == "/settings/subscription"
          },
          %{
            label: gettext("Integrations"),
            icon: "lucide-plug",
            href: "/settings/integrations",
            active?: current_path == "/settings/integrations"
          }
        ]
      else
        []
      end

    base_items ++ admin_items
  end
end
