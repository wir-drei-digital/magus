defmodule MagusWeb.Workbench.Resources.AgentView.Sections.Automation do
  @moduledoc """
  Automation agent settings section, ported from AgentAutomationLive.
  """
  use MagusWeb, :live_component

  use Gettext, backend: MagusWeb.Gettext

  alias AshPhoenix.Form

  @impl true
  def update(%{agent: agent, current_user: current_user} = assigns, socket) do
    form =
      agent
      |> Form.for_update(:update, actor: current_user, forms: [auto?: true])
      |> to_form()

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:form, form)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div data-section="automation" class="p-4">
      <div class="flex justify-end mb-4">
        <button
          id={"run-now-#{@id}"}
          type="button"
          phx-click="run_now"
          phx-target={@myself}
          class="btn btn-primary btn-sm"
        >
          <.icon name="lucide-zap" class="w-4 h-4" />
          {gettext("Run now")}
        </button>
      </div>

      <.form for={@form} phx-change="validate" phx-submit="save" phx-target={@myself}>
        <div class="space-y-6">
          <.content_card
            title={gettext("Heartbeat")}
            icon="lucide-timer"
            subtitle={
              gettext(
                "When enabled, the agent wakes up periodically to check its inbox and triage events."
              )
            }
          >
            <div class="space-y-4">
              <.input
                field={@form[:heartbeat_enabled]}
                type="checkbox"
                label={gettext("Enable heartbeat")}
              />

              <div :if={AshPhoenix.Form.value(@form.source, :heartbeat_enabled)}>
                <.input
                  field={@form[:heartbeat_default_interval_minutes]}
                  type="number"
                  label={gettext("Interval (minutes)")}
                  min="5"
                  max="1440"
                />
                <p class="text-xs text-base-content/50 mt-1">
                  {gettext(
                    "How often the agent checks for new events. Default: 360 minutes (6 hours)."
                  )}
                </p>
              </div>
            </div>
          </.content_card>

          <.content_card
            title={gettext("Triage Instructions")}
            icon="lucide-clipboard-list"
            subtitle={
              gettext(
                "Optional guidance for how the agent should prioritize and process inbox events. Leave empty for default behavior."
              )
            }
          >
            <.input
              field={@form[:heartbeat_instructions]}
              type="textarea"
              label={gettext("Instructions")}
              placeholder={
                gettext(
                  "e.g. Prioritize error logs over RSS items. Ignore debug-level entries. Escalate critical crashes immediately."
                )
              }
              class="textarea h-32 font-mono text-sm"
            />
          </.content_card>

          <.content_card
            title={gettext("Safety Limits")}
            icon="lucide-shield-alert"
            subtitle={
              gettext("Prevent runaway costs by limiting how much the agent can do autonomously.")
            }
          >
            <div class="grid grid-cols-2 gap-4">
              <div>
                <.input
                  field={@form[:max_daily_runs]}
                  type="number"
                  label={gettext("Max daily runs")}
                  min="0"
                  placeholder={gettext("Unlimited")}
                />
                <p class="text-xs text-base-content/50 mt-1">
                  {gettext("0 or empty = unlimited")}
                </p>
              </div>
              <div>
                <.input
                  field={@form[:max_tokens_per_run]}
                  type="number"
                  label={gettext("Max tokens per run")}
                  min="0"
                  placeholder={gettext("Unlimited")}
                />
                <p class="text-xs text-base-content/50 mt-1">
                  {gettext("0 or empty = unlimited")}
                </p>
              </div>
            </div>
          </.content_card>
        </div>

        <div class="flex justify-end mt-6">
          <button
            type="submit"
            class="btn btn-primary btn-sm"
            phx-disable-with={gettext("Saving...")}
          >
            {gettext("Save")}
          </button>
        </div>
      </.form>
    </div>
    """
  end

  @impl true
  def handle_event("validate", %{"form" => params}, socket) do
    form =
      socket.assigns.form.source
      |> Form.validate(params)
      |> to_form()

    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("run_now", _params, socket) do
    agent = socket.assigns.agent
    user = socket.assigns.current_user

    case Magus.Agents.Support.HomeConversation.ensure(user.id, agent.id) do
      {:ok, home} ->
        attrs = %{
          kind: :delegate,
          source: :manual_trigger,
          source_conversation_id: home.id,
          target_conversation_id: home.id,
          target_agent_id: agent.id,
          initiator_user_id: user.id,
          request_id: "manual-#{Ash.UUID.generate()}",
          idempotency_key: nil,
          objective: "Manual wake-up triggered from UI"
        }

        case Magus.Agents.RunOrchestrator.enqueue(attrs) do
          {:ok, run} ->
            user_label = user.display_name || to_string(user.email) || "user"

            _ =
              Magus.Agents.HeartbeatEventMessage.create(home.id,
                run_id: run.id,
                source: :manual_trigger,
                user_label: user_label
              )

            {:noreply, put_flash(socket, :info, gettext("Run started"))}

          {:error, reason} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               gettext("Could not start run: %{reason}", reason: inspect(reason))
             )}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not load home conversation"))}
    end
  end

  def handle_event("save", %{"form" => params}, socket) do
    case Form.submit(socket.assigns.form.source, params: params) do
      {:ok, _agent} ->
        {:noreply, put_flash(socket, :info, gettext("Automation settings saved"))}

      {:error, form} ->
        {:noreply, assign(socket, :form, to_form(form))}
    end
  end
end
