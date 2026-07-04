defmodule Magus.LiveE2ECase do
  @moduledoc """
  Base test case for live E2E tests that make real LLM API calls.

  Requires OPENROUTER_API_KEY environment variable to be set.
  Uses x-ai/grok-4.3 via OpenRouter for all tests.

  ## Usage

      defmodule MyLiveE2ETest do
        use Magus.LiveE2ECase, async: false

        test "basic chat", %{user: user, model: model} do
          conversation = create_conversation(user, model)
          subscribe_to_agent(conversation.id)
          send_user_message(conversation, user, "Hello!")
          assert_response_complete()
        end
      end
  """

  use ExUnit.CaseTemplate

  alias Magus.Chat
  alias Magus.Usage

  @live_model_key "openrouter:mistralai/ministral-3b-2512"

  # The curated catalog is empty in the open-core build (`Magus.Models.Catalog`
  # has `@models []`; the data lives in the commercial repo), so the live
  # model's LLMDB metadata is defined inline here in the string-keyed shape
  # `Magus.Models.Catalog.to_llm_metadata/1` produces. CatalogSync reads this
  # from the DB row when registering the model in the LLMDB :custom registry.
  @live_model_metadata %{
    "context" => 131_072,
    "output_limit" => 8_192,
    "input_cost" => 0.04,
    "output_cost" => 0.04
  }

  using do
    quote do
      import Magus.Generators
      import Magus.LiveE2ECase
      import Magus.LiveE2E.Assertions

      alias Magus.Chat
      alias Magus.Accounts
      alias Magus.Library

      @moduletag :e2e_live
      @moduletag timeout: 180_000
    end
  end

  setup _tags do
    api_key = System.get_env("OPENROUTER_API_KEY")

    unless api_key do
      raise "OPENROUTER_API_KEY not set — skipping live E2E tests. " <>
              "Set the env var to run: OPENROUTER_API_KEY=sk-or-... mix test.e2e.live"
    end

    # Ecto sandbox in shared mode — agent processes need DB access
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Magus.Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    # Swap LLM client to real implementation
    original_client = Application.get_env(:magus, :llm_client)
    Application.put_env(:magus, :llm_client, Magus.Agents.Clients.LLM)
    on_exit(fn -> Application.put_env(:magus, :llm_client, original_client) end)

    # Swap in the real sandbox provider when SANDBOX_PROVIDER is set.
    # config/test.exs pins provider :test and stubs the Daytona client
    # (Req.Test plug + .invalid control URL) so ordinary tests never provision
    # real services; runtime.exs skips the SANDBOX_PROVIDER override in test
    # env. Live E2E honors the env var here instead — :sandbox-tagged tests
    # hit the real control plane, and still skip gracefully via their setup
    # probe when the provider has no working credentials.
    setup_live_sandbox_provider()

    # Start test-scoped InstanceManager (same pattern as PlaywrightCase)
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

    # Create standard fixtures
    model = create_live_model()
    user = create_live_user()
    setup_live_subscription(user)

    %{model: model, user: user}
  end

  defp setup_live_sandbox_provider do
    case System.get_env("SANDBOX_PROVIDER") do
      provider_str when provider_str in ["sprites", "daytona"] ->
        provider = String.to_existing_atom(provider_str)

        original_sandbox = Application.get_env(:magus, Magus.Sandbox)
        original_daytona = Application.get_env(:magus, Magus.Sandbox.Clients.Daytona)

        Application.put_env(
          :magus,
          Magus.Sandbox,
          Keyword.put(original_sandbox || [], :provider, provider)
        )

        # Strip the test stub (plug + invalid control URL) so the client
        # falls back to its real production base URLs; api_key and sizing
        # come through from runtime.exs untouched.
        Application.put_env(
          :magus,
          Magus.Sandbox.Clients.Daytona,
          Keyword.drop(original_daytona || [], [:req_options, :control_base_url])
        )

        on_exit(fn ->
          Application.put_env(:magus, Magus.Sandbox, original_sandbox)
          Application.put_env(:magus, Magus.Sandbox.Clients.Daytona, original_daytona)
        end)

      _ ->
        :ok
    end
  end

  @doc """
  Create the model record pointing to the real OpenRouter model.

  Since LLMDB is synced from DB rows (CatalogSync), the fixture must mirror
  production shape: a Provider row, the model linked to it with llm_metadata
  (tools capability, limits; see @live_model_metadata), then a synchronous
  catalog reload so ReqLLM resolves the spec with the same metadata as a
  deployed instance.
  """
  def create_live_model do
    provider =
      case Magus.Models.get_provider_by_slug("openrouter") do
        {:ok, provider} ->
          provider

        _ ->
          Magus.Models.create_provider!(
            %{name: "OpenRouter", slug: "openrouter", req_llm_id: "openrouter"},
            authorize?: false
          )
      end

    llm_metadata = @live_model_metadata

    # Find-or-create by key. A materialized catalog row for the live model can
    # exist outside the Ecto sandbox (e.g. seeded into a real DB); the create
    # path would then crash the whole suite with "key has already been taken".
    # Reuse + update an existing row instead of recreating it (it may carry FK
    # references that forbid deletion).
    model =
      case find_live_model() do
        nil -> create_live_model_row(provider, llm_metadata)
        existing -> update_live_model_row(existing, provider, llm_metadata)
      end

    assign_chat_default_role(model.id)

    :ok = Magus.Models.CatalogSync.reload()

    model
  end

  # Look up the live model by its stable key. Returns the Model struct or nil.
  defp find_live_model do
    require Ash.Query

    Magus.Chat.Model
    |> Ash.Query.filter(key == ^@live_model_key)
    |> Ash.read!(authorize?: false)
    |> List.first()
  end

  # Create the live model row, then converge it through the same attribute step
  # the find/update path uses. The `model/1` generator's defaults do NOT thread
  # `allowed_providers`, so a generator-only create leaves the row with the
  # attribute default `[]` (empty allowlist). Routing both paths through
  # update_live_model_row/3 guarantees the create path persists the same desired
  # attrs (including allowed_providers) as the update path.
  defp create_live_model_row(provider, llm_metadata) do
    import Magus.Generators

    generate(
      model(
        name: "Ministral 3B",
        key: @live_model_key,
        provider: "openrouter",
        api_provider: :openrouter,
        active?: true,
        supports_tools?: true,
        model_provider_id: provider.id,
        llm_metadata: llm_metadata
      )
    )
    |> update_live_model_row(provider, llm_metadata)
  end

  # Apply the desired shape via the Model `:update` action (model.ex accepts
  # :allowed_providers, :api_provider, :supports_tools?, :model_provider_id,
  # :active?, :llm_metadata on both :create and :update). Used by BOTH the
  # create path (to thread allowed_providers the generator drops) and the reuse
  # path (to normalize a pre-existing row).
  #
  # Pin to the mistral provider so OpenRouter routing is deterministic. Without
  # an allowlist, build_provider_routing sends only data_collection: deny, and
  # OpenRouter intermittently finds no ministral-3b provider honoring it (HTTP
  # 404 "No allowed providers are specified"). "mistral" routes to EU, which the
  # default user data_region_preference (US/EU/CH) permits. Test-only: prod
  # routing for the catalog entry is untouched.
  defp update_live_model_row(model, provider, llm_metadata) do
    Ash.update!(
      model,
      %{
        active?: true,
        supports_tools?: true,
        api_provider: :openrouter,
        allowed_providers: ["mistral"],
        model_provider_id: provider.id,
        llm_metadata: llm_metadata
      },
      authorize?: false
    )
  end

  # Idempotent role assignment. The :assign action upserts on the role identity,
  # so re-running is safe; we still guard against a stale already-assigned error.
  defp assign_chat_default_role(model_id) do
    case Magus.Models.assign_role(%{role: "chat_default", model_id: model_id},
           authorize?: false
         ) do
      {:ok, _assignment} -> :ok
      {:error, %Ash.Error.Invalid{}} -> :ok
    end
  end

  @doc "Create a test user with password auth."
  def create_live_user do
    import Magus.Generators
    generate(user())
  end

  @doc "Create a generous usage plan and subscription for the user."
  def setup_live_subscription(user) do
    {:ok, plan} =
      Usage.create_usage_plan(
        %{
          key: "live-e2e-plan-#{System.unique_integer([:positive])}",
          name: "Live E2E Plan",
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

  @doc "Create a conversation linked to the live model."
  def create_conversation(user, model, opts \\ []) do
    import Magus.Generators

    generate(
      conversation(
        actor: user,
        selected_model_id: model.id,
        chat_mode: Keyword.get(opts, :chat_mode, :chat),
        system_prompt: Keyword.get(opts, :system_prompt)
      )
    )
  end

  @doc "Subscribe to PubSub agent signals for a conversation."
  def subscribe_to_agent(conversation_id) do
    MagusWeb.Endpoint.subscribe("agents:#{conversation_id}")
  end

  @doc """
  Send a user message through the full pipeline.

  Uses the :send_user_message action which triggers SignalAgent -> Dispatcher -> Agent.
  """
  def send_user_message(conversation, user, text) do
    {:ok, message} =
      Chat.send_user_message(
        %{text: text, conversation_id: conversation.id},
        actor: user
      )

    message
  end
end
