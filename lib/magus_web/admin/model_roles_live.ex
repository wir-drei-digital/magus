defmodule MagusWeb.Admin.ModelRolesLive do
  @moduledoc """
  Admin view for internal model roles (`Magus.Models.Roles`).

  Every place the app itself (not the user) needs a model is a *role*. This
  view shows the full registry, each role's current resolution and where it
  came from (`Roles.explain/1`), and lets an admin override resolution by
  assigning a catalog model to a role, resetting an assignment, or disabling
  a nilable role's feature.

  Writes go through `Magus.Models` Ash interfaces with the acting admin as
  actor (RoleAssignment policies enforce admin); each `handle_event` also
  guards `admin?/1` explicitly, mirroring the providers/models admin views.
  Role keys arriving as params are untrusted strings: they are matched against
  the code registry rather than converted to atoms.
  """
  use MagusWeb, :live_view

  require Ash.Query

  alias Magus.Chat.Model
  alias Magus.Models.Roles
  alias MagusWeb.Layouts

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Model roles")
      |> assign(:current_path, "/admin/models")
      |> assign(:model_options, model_options())
      |> load_roles()

    {:ok, socket}
  end

  # Build the role rows: each role plus its current {value, source} resolution.
  # `has_assignment?` reflects whether an actual DB assignment row exists, which
  # gates the Reset button: a config-set nil (no row) is not resettable.
  defp load_roles(socket) do
    rows =
      Enum.map(Roles.all(), fn role ->
        {value, source} = Roles.explain(role.key)

        has_assignment? =
          match?({:ok, _}, Magus.Models.get_role_assignment(Atom.to_string(role.key)))

        %{role: role, value: value, source: source, has_assignment?: has_assignment?}
      end)

    assign(socket, :rows, rows)
  end

  # Active catalog models (internal models included) for the per-role select.
  # Active-only: assigning a disabled model to a role would resolve to a model
  # the rest of the app won't use. Capability filtering happens per row in the
  # template against output_modalities.
  defp model_options do
    Model
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(active? == true)
    |> Ash.Query.sort(name: :asc)
    |> Ash.read!(authorize?: false)
  end

  # Match an untrusted role param against the registry. No atom conversion.
  defp resolve_role_param(param) when is_binary(param) do
    Enum.find(Roles.all(), &(Atom.to_string(&1.key) == param))
  end

  defp resolve_role_param(_), do: nil

  @impl true
  def handle_event("assign_role", %{"role" => role_param} = params, socket) do
    if admin?(socket) do
      with %{} = role <- resolve_role_param(role_param),
           model_id when is_binary(model_id) and model_id != "" <- params["model_id"],
           {:ok, _assignment} <-
             Magus.Models.assign_role(
               %{role: Atom.to_string(role.key), model_id: model_id},
               actor: socket.assigns.current_user
             ) do
        {:noreply,
         socket
         |> put_flash(:info, "Assigned model to #{role.key}")
         |> load_roles()}
      else
        nil ->
          {:noreply, put_flash(socket, :error, "Unknown role")}

        # Empty selection ("-- use default --"): treat as a reset.
        empty when empty in ["", nil] ->
          reset_role(socket, role_param)

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to assign model")}
      end
    else
      {:noreply, put_flash(socket, :error, "You don't have access to this action.")}
    end
  end

  @impl true
  def handle_event("disable_role", %{"role" => role_param}, socket) do
    if admin?(socket) do
      case resolve_role_param(role_param) do
        %{nilable?: true} = role ->
          case Magus.Models.assign_role(
                 %{role: Atom.to_string(role.key), model_id: nil, disabled?: true},
                 actor: socket.assigns.current_user
               ) do
            {:ok, _} ->
              {:noreply,
               socket
               |> put_flash(:info, "Disabled #{role.key}")
               |> load_roles()}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Failed to disable role")}
          end

        # Non-nilable or unknown role: disabling is not offered for these.
        _ ->
          {:noreply, put_flash(socket, :error, "This role cannot be disabled")}
      end
    else
      {:noreply, put_flash(socket, :error, "You don't have access to this action.")}
    end
  end

  @impl true
  def handle_event("reset_role", %{"role" => role_param}, socket) do
    if admin?(socket) do
      reset_role(socket, role_param)
    else
      {:noreply, put_flash(socket, :error, "You don't have access to this action.")}
    end
  end

  # Destroy any DB assignment for the role, falling back to config/default
  # resolution. Idempotent: a missing assignment is a no-op.
  defp reset_role(socket, role_param) do
    with %{} = role <- resolve_role_param(role_param),
         {:ok, assignment} <- Magus.Models.get_role_assignment(Atom.to_string(role.key)),
         :ok <-
           Magus.Models.destroy_role_assignment(assignment, actor: socket.assigns.current_user) do
      {:noreply,
       socket
       |> put_flash(:info, "Reset #{role.key} to default")
       |> load_roles()}
    else
      nil ->
        {:noreply, put_flash(socket, :error, "Unknown role")}

      # No assignment row — already at config/default resolution.
      {:error, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Nothing to reset for this role.")
         |> load_roles()}
    end
  end

  defp admin?(socket), do: socket.assigns.current_user.is_admin == true

  # Models whose output modalities satisfy the role's capability.
  # :embedding has no matching output modality in the model catalog today, so
  # the select renders empty with hint text.
  defp options_for_capability(models, :chat),
    do: Enum.filter(models, &("text" in (&1.output_modalities || [])))

  defp options_for_capability(models, :image),
    do: Enum.filter(models, &("image" in (&1.output_modalities || [])))

  defp options_for_capability(models, :video),
    do: Enum.filter(models, &("video" in (&1.output_modalities || [])))

  defp options_for_capability(_models, :embedding), do: []

  defp source_label(:assignment), do: "assignment"
  defp source_label(:disabled), do: "disabled"
  defp source_label(:config), do: "config"
  defp source_label(:default), do: "built-in default"
  defp source_label({:fallback, role}), do: "fallback via #{role}"
  defp source_label(:none), do: "none"

  defp capability_label(:chat), do: "Chat"
  defp capability_label(:embedding), do: "Embedding"
  defp capability_label(:image), do: "Image"
  defp capability_label(:video), do: "Video"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_user={@current_user} current_path={@current_path}>
      <div class="space-y-6">
        <%!-- Header --%>
        <div class="flex items-center gap-4">
          <.link navigate={~p"/admin/models"} class="btn btn-ghost btn-sm btn-circle">
            <.icon name="lucide-arrow-left" class="w-5 h-5" />
          </.link>
          <div>
            <h1 class="text-2xl font-bold text-base-content">Model roles</h1>
            <p class="text-base-content/60 text-sm mt-1">
              Internal roles where the app itself picks a model. Assign a catalog model to
              override config/default resolution.
            </p>
          </div>
        </div>

        <div class="card bg-base-200 border border-base-300 overflow-hidden">
          <div class="overflow-x-auto">
            <table class="table table-sm" data-test-roles-table>
              <thead>
                <tr class="bg-base-300/50">
                  <th>Role</th>
                  <th class="text-center">Capability</th>
                  <th>Current resolution</th>
                  <th>Assign model</th>
                  <th class="text-center">Actions</th>
                </tr>
              </thead>
              <tbody>
                <.role_row
                  :for={row <- @rows}
                  row={row}
                  model_options={@model_options}
                />
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </Layouts.admin>
    """
  end

  attr :row, :map, required: true
  attr :model_options, :list, required: true

  defp role_row(assigns) do
    role = assigns.row.role
    options = options_for_capability(assigns.model_options, role.capability)

    assigns =
      assigns
      |> assign(:role, role)
      |> assign(:options, options)
      |> assign(:assigned?, assigns.row.has_assignment?)

    ~H"""
    <tr class="hover:bg-base-300/30 align-top" data-test-role={@role.key}>
      <td>
        <div class="font-medium">
          <code class="text-xs bg-base-300 px-1 py-0.5 rounded">{@role.key}</code>
        </div>
        <p class="text-xs text-base-content/60 mt-1 max-w-md">{@role.description}</p>
        <p
          :if={@role.capability == :embedding}
          class="text-xs text-warning mt-1 max-w-md"
          data-test-embedding-warning
        >
          Changing the embedding model changes vector dimensions and requires re-embedding
          all stored vectors.
        </p>
      </td>
      <td class="text-center">
        <span class="badge badge-ghost badge-sm">{capability_label(@role.capability)}</span>
      </td>
      <td>
        <div class="text-sm font-mono">
          {@row.value || "—"}
        </div>
        <div class="text-xs text-base-content/50">
          {source_label(@row.source)}
        </div>
      </td>
      <td>
        <form phx-change="assign_role" data-test-role-form={@role.key}>
          <input type="hidden" name="role" value={@role.key} />
          <select
            name="model_id"
            class="select select-bordered select-xs w-full max-w-56"
            disabled={@options == []}
          >
            <option value="">-- use config/default --</option>
            <option
              :for={model <- @options}
              value={model.id}
              selected={@row.source == :assignment and @row.value == model.key}
            >
              {model.name}
            </option>
          </select>
        </form>
        <p :if={@options == []} class="text-xs text-base-content/40 mt-1">
          No active models match this capability.
        </p>
      </td>
      <td>
        <div class="flex items-center justify-center gap-1">
          <button
            :if={@role.nilable?}
            type="button"
            phx-click="disable_role"
            phx-value-role={@role.key}
            data-test-disable-role={@role.key}
            class="btn btn-ghost btn-xs"
            title="Disable this feature"
          >
            Disable
          </button>
          <button
            :if={@assigned?}
            type="button"
            phx-click="reset_role"
            phx-value-role={@role.key}
            data-test-reset-role={@role.key}
            class="btn btn-ghost btn-xs"
            title="Remove assignment; revert to config/default"
          >
            Reset
          </button>
        </div>
      </td>
    </tr>
    """
  end
end
