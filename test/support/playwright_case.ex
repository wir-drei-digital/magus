defmodule MagusWeb.PlaywrightCase do
  @moduledoc """
  Test case for browser-based E2E tests using PhoenixTest.Playwright.

  Uses shared Ecto sandbox mode so agent processes (children of InstanceManager)
  can access the test database. Forces `async: false`.

  The sandbox is managed by `PhoenixTest.Playwright.Case` (with `shared: true`
  when `async: false`), so we do NOT manually start a sandbox owner here.

  ## Usage

      defmodule MagusWeb.MyChatE2ETest do
        use MagusWeb.PlaywrightCase

        @tag :e2e
        test "user sends message", %{conn: conn} do
          user = generate(user())
          setup_subscription_for_user(user)
          conversation = generate(conversation(actor: user))

          conn
          |> authenticate(user)
          |> visit(~p"/chat/\#{conversation.id}")
          |> assert_has("body .phx-connected")
          |> type("#chat-textarea", "Hello!")
          |> click("button[title='Send message']")
          |> assert_has(".prose", text: "AI response")
        end
      end
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use PhoenixTest.Playwright.Case, async: false
      use MagusWeb, :verified_routes

      import Magus.Generators
      import Mox
      import MagusWeb.PlaywrightCase

      alias Magus.Chat
      alias Magus.Test.Mocks.LLMMock
      alias Magus.Test.Mocks.ImageGenMock
      alias Magus.Test.Mocks.VideoGenMock
      alias Magus.Test.MockResponses

      setup :verify_on_exit!
    end
  end

  setup _tags do
    # Global Mox so agent processes in InstanceManager can access expectations
    Mox.set_mox_global()

    # Sandbox is managed by PhoenixTest.Playwright.Case (shared: true for async: false).
    # We start a test-scoped InstanceManager for agent processing. This works because
    # the global InstanceManager is disabled in config/test.exs (:jido_instance_manager, enabled: false).

    store = {Magus.Agents.Persistence.PostgresStore, []}

    start_supervised!(
      {Jido.Agent.InstanceManager,
       [
         name: :conversations,
         agent: Magus.Agents.ConversationAgent,
         idle_timeout: :timer.minutes(5),
         storage: store,
         agent_opts: [jido: Magus.Jido, agent_module: Magus.Agents.ConversationAgent]
       ]}
    )

    # Default stubs for LLM functions that may be called by background processes
    # (e.g., title generation via Oban). Tests override with specific stubs/expects.
    Mox.stub(Magus.Test.Mocks.LLMMock, :generate_text, fn _model, _context, _opts ->
      Magus.Test.MockResponses.generate_text_response("Test Title")
    end)

    Mox.stub(Magus.Test.Mocks.LLMMock, :generate_object, fn _model, _prompt, _schema, _opts ->
      Magus.Test.MockResponses.generate_object_response(%{"operations" => []})
    end)

    :ok
  end

  @doc """
  Authenticate a Playwright session as the given user.

  Sets the session cookie with the user's authentication token,
  matching what AshAuthentication stores (key: `"user_token"`).
  """
  def authenticate(conn, user) do
    import PhoenixTest.Playwright

    token = user.__metadata__.token

    unless is_binary(token) do
      raise "User has no authentication token in __metadata__. " <>
              "Ensure the user was created via the :register_with_password action."
    end

    add_session_cookie(
      conn,
      [value: %{"user_token" => token}],
      MagusWeb.Endpoint.session_options()
    )
  end

  @doc """
  Create a usage plan and subscription for a user with generous test limits.
  """
  def setup_subscription_for_user(user, _opts \\ []) do
    alias Magus.Usage

    {:ok, plan} =
      Usage.create_usage_plan(
        %{
          key: "test-plan-#{System.unique_integer([:positive])}",
          name: "Test Plan",
          storage_bytes: 1_000_000_000,
          max_upload_bytes: 100_000_000
        },
        authorize?: false
      )

    {:ok, _subscription} =
      Usage.create_user_subscription(
        %{user_id: user.id, usage_plan_id: plan.id, status: :active},
        authorize?: false
      )
  end

  @doc """
  Confirm a user's email so they can access the chat interface.
  """
  def confirm_user(user) do
    user
    |> Ash.Changeset.for_update(:update_profile, %{})
    |> Ash.Changeset.force_change_attribute(:confirmed_at, DateTime.utc_now())
    |> Ash.update!(authorize?: false)
  end

  @doc """
  Create a default chat model for testing.
  """
  def create_default_model do
    model =
      Magus.Generators.generate(
        Magus.Generators.model(
          name: "Test Model",
          key: "test/model",
          active?: true
        )
      )

    {:ok, _} =
      Magus.Models.assign_role(%{role: "chat_default", model_id: model.id},
        authorize?: false
      )

    model
  end
end
