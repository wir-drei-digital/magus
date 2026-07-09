defmodule Magus.Eval.Harness do
  @moduledoc """
  Stands up a real agent environment for an eval run by reusing the
  `Magus.LiveE2ECase` fixture logic: swap the LLM client to the real one, start
  a scoped `Jido.Agent.InstanceManager` named `:conversations`, and create an
  isolated throwaway eval user, workspace, model, and active subscription.

  Placement: this module lives under `test/support/eval/` (compiled in the test
  env via `elixirc_paths(:test)`) rather than `lib/`. It depends on test-only
  modules (`Magus.Generators`, `Magus.LiveE2ECase`), so placing it in `lib/`
  would break `MIX_ENV=dev`/`prod` compilation and the running dev server.

  The fixture builders (`create_live_model/0`, `create_live_user/0`,
  `setup_live_subscription/1`) are reused directly from `Magus.LiveE2ECase` to
  keep a single source of truth shared with the live E2E suite.

  An ExUnit case may set up the Ecto sandbox and call `setup/1`. A Mix task
  would use the configured eval Repo directly (no Ecto sandbox).
  """

  @doc """
  Builds the real agent environment for an eval run.

  Returns `{:ok, %{user: user, model: model, workspace: workspace}}`.

  Idempotent with respect to the `:conversations` InstanceManager: it is started
  only if not already running, so repeat calls in the same VM are safe.
  """
  def setup(_opts \\ []) do
    Application.put_env(:magus, :llm_client, Magus.Agents.Clients.LLM)

    # The test env mocks the Super Brain extraction LLM and embedder so unit
    # tests stay offline; an eval run must exercise the real pipeline or the
    # graphs and claims built during ingest are mock artifacts and the
    # super_brain context block injects noise. Swap both to the production
    # modules, mirroring the chat-client swap above.
    Application.put_env(:magus, :super_brain_llm_client, Magus.SuperBrain.LLMClient.ReqLLM)
    Application.put_env(:magus, :super_brain_embedder, Magus.Embeddings.OpenAIEmbedder)

    Application.put_env(
      :magus,
      :super_brain_extraction_embedder,
      Magus.Embeddings.OpenAIBatchEmbedder
    )

    store = {Magus.Agents.Persistence.PostgresStore, []}

    case Process.whereis(:conversations) do
      nil ->
        {:ok, _pid} =
          Jido.Agent.InstanceManager.start_link(
            name: :conversations,
            agent: Magus.Agents.ConversationAgent,
            idle_timeout: :timer.minutes(5),
            storage: store,
            agent_opts: [jido: Magus.Jido, agent_module: Magus.Agents.ConversationAgent]
          )

      _pid ->
        :ok
    end

    # Reuse the exact fixture builders from LiveE2ECase so eval and e2e stay aligned.
    model = Magus.LiveE2ECase.create_live_model()
    user = Magus.LiveE2ECase.create_live_user()
    Magus.LiveE2ECase.setup_live_subscription(user)
    workspace = Magus.Generators.generate(Magus.Generators.workspace(actor: user))

    {:ok, %{user: user, model: model, workspace: workspace}}
  end

  @doc """
  Best-effort cleanup of the throwaway eval user.

  Wrapped in a rescue so teardown never raises: the user resource has no destroy
  action today, so this is a no-op for now (the throwaway user persists in the
  eval DB). If a destroy action is later added, it will be used automatically.
  """
  def teardown(%{user: user}) do
    Ash.destroy(user, authorize?: false)
    :ok
  rescue
    _ -> :ok
  end
end
