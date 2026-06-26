# assert_receive_timeout only extends how long a *failing* assert_receive/assert_push
# waits; passing assertions return as soon as the message arrives. The 100ms default
# is too tight for PubSub→channel→push round-trips while the async phase saturates CPU.
ExUnit.start(
  exclude: [skip: true, e2e: true, e2e_live: true, sandbox: true, slow: true],
  assert_receive_timeout: 1_000
)

Ecto.Adapters.SQL.Sandbox.mode(Magus.Repo, :manual)

# Set up Mox mocks
Mox.defmock(Magus.Test.Mocks.LLMMock, for: Magus.Agents.Clients.LLMBehaviour)
Mox.defmock(Magus.Test.Mocks.ImageGenMock, for: Magus.Agents.Clients.ImageGenBehaviour)
Mox.defmock(Magus.Test.Mocks.VideoGenMock, for: Magus.Agents.Clients.VideoGenBehaviour)

Mox.defmock(Magus.Test.Mocks.OpenRouterVideoMock,
  for: Magus.Agents.Clients.OpenRouterVideoBehaviour
)

Mox.defmock(Magus.SuperBrain.LLMMock, for: Magus.SuperBrain.LLMClient)
Mox.defmock(Magus.Embeddings.EmbedderMock, for: Magus.Embeddings.Embedder)
Mox.defmock(Magus.Embeddings.BatchEmbedderMock, for: Magus.Embeddings.BatchEmbedder)
# Start Playwright supervisor for E2E browser tests (only when E2E tests are included).
# CLI --include flags are not yet in ExUnit.configuration() when test_helper.exs runs,
# so we check the E2E env var set by the test.e2e mix alias.
if System.get_env("E2E") == "1" do
  # Ensure node is available for Playwright (handles nvm)
  unless System.find_executable("node") do
    nvm_dir = System.get_env("NVM_DIR") || Path.expand("~/.nvm")

    nvm_node_bin =
      case Path.wildcard(Path.join([nvm_dir, "versions", "node", "*", "bin"])) do
        paths when paths != [] -> List.last(paths)
        [] -> nil
      end

    if nvm_node_bin do
      System.put_env("PATH", "#{nvm_node_bin}:#{System.get_env("PATH")}")
    end
  end

  {:ok, _} = PhoenixTest.Playwright.Supervisor.start_link()
  Application.put_env(:phoenix_test, :base_url, MagusWeb.Endpoint.url())
end
