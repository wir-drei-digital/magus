defmodule Magus.LiveE2EBrowserCase do
  @moduledoc """
  Browser-based test case for live E2E tests using Playwright.
  Combines real LLM calls with full browser rendering.

  Requires both OPENROUTER_API_KEY and E2E_LIVE=1.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use PhoenixTest.Playwright.Case, async: false
      use MagusWeb, :verified_routes

      import Magus.Generators
      import Magus.LiveE2ECase
      import Magus.LiveE2E.Assertions
      import Magus.LiveE2EBrowserCase

      alias Magus.Chat
      alias Magus.Test.Mocks.LLMMock
      alias Magus.Test.MockResponses

      @moduletag :e2e_live
      @moduletag :e2e_browser
      @moduletag timeout: 240_000
    end
  end

  setup _tags do
    api_key = System.get_env("OPENROUTER_API_KEY")

    unless api_key do
      raise "OPENROUTER_API_KEY not set — skipping live E2E browser tests"
    end

    # Global Mox so background processes can access stubs (for title generation etc.)
    Mox.set_mox_global()

    # Swap to real LLM client for core chat
    original_client = Application.get_env(:magus, :llm_client)
    Application.put_env(:magus, :llm_client, Magus.Agents.Clients.LLM)

    on_exit(fn ->
      Application.put_env(:magus, :llm_client, original_client)
    end)

    # Stub generate_text and generate_object for background tasks that use the mock client
    # (e.g., title generation via Oban, memory extraction)
    Mox.stub(Magus.Test.Mocks.LLMMock, :generate_text, fn _model, _context, _opts ->
      Magus.Test.MockResponses.generate_text_response("Test Title")
    end)

    Mox.stub(Magus.Test.Mocks.LLMMock, :generate_object, fn _model, _prompt, _schema, _opts ->
      Magus.Test.MockResponses.generate_object_response(%{"operations" => []})
    end)

    # Start test-scoped InstanceManager
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

    # Fixtures
    model = Magus.LiveE2ECase.create_live_model()
    user = Magus.LiveE2ECase.create_live_user()
    Magus.LiveE2ECase.setup_live_subscription(user)

    %{model: model, user: user}
  end

  @doc "Authenticate a Playwright session (same as PlaywrightCase)."
  def authenticate(conn, user) do
    import PhoenixTest.Playwright

    token = user.__metadata__.token

    unless is_binary(token) do
      raise "User has no authentication token. Ensure user was created via :register_with_password."
    end

    add_session_cookie(
      conn,
      [value: %{"user_token" => token}],
      MagusWeb.Endpoint.session_options()
    )
  end
end
