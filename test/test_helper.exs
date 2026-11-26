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
Mox.defmock(Magus.CaptchaImplMock, for: Turnstile.Behaviour)
