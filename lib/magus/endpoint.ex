defmodule Magus.Endpoint do
  @moduledoc """
  Endpoint facade for the open-core / `magus_cloud` split.

  Core code must not name `MagusWeb.Endpoint` directly. It calls this facade,
  which forwards `url/0`, `subscribe/2`, `unsubscribe/1`, and `broadcast/3` to
  the endpoint configured at `:magus, :endpoint` (default `MagusWeb.Endpoint`).

  `magus_cloud` overrides the seam with `config :magus, :endpoint,
  MagusCloudWeb.Endpoint`, so PubSub topics and generated URLs resolve under
  either web layer without touching core code.

  Only the PubSub/URL surface used by core is exposed here. Endpoint lifecycle
  (e.g. `config_change/2`) stays on the concrete endpoint module.

  ## Known direct couplings to `MagusWeb.Endpoint` (by design, for now)

  Two core surfaces still name `MagusWeb.Endpoint` directly rather than going
  through this facade. Both are safe in the combined app and are documented here
  so the repo split reconciles them deliberately:

    * **Resource PubSub broadcasts.** Eight core resources declare
      `pub_sub do ... module MagusWeb.Endpoint end` (Chat.Conversation, Message,
      ConversationMember; Files.File; Chat.Folder; Agents.CustomAgent;
      Library.Prompt; Notifications.Notification). Ash's `pub_sub` notifier needs
      a literal endpoint module at compile time. This works across web layers
      only because every endpoint shares `pubsub_server: Magus.PubSub`
      (config.exs), so a subscriber on `Magus.Endpoint.subscribe/2` (which uses
      the configured endpoint's PubSub) receives these broadcasts regardless of
      which endpoint published them. Invariant: all endpoints MUST share
      `pubsub_server: Magus.PubSub`.

    * **Token signing secret.** `Magus.Accounts.User` and a few controllers sign
      Phoenix tokens with `MagusWeb.Endpoint`'s `secret_key_base`. At the split,
      either keep a shared `secret_key_base` across web layers or thread
      `Magus.Endpoint.endpoint()` through the token calls so tokens stay valid
      under `magus_cloud`.
  """

  @doc "The configured endpoint module, defaulting to `MagusWeb.Endpoint`."
  @spec endpoint() :: module()
  def endpoint, do: Application.get_env(:magus, :endpoint, MagusWeb.Endpoint)

  @doc "Base URL of the configured endpoint."
  @spec url() :: String.t()
  def url, do: endpoint().url()

  @doc "Subscribe the caller to `topic` on the configured endpoint's PubSub."
  @spec subscribe(binary(), keyword()) :: :ok | {:error, term()}
  def subscribe(topic, opts \\ []), do: endpoint().subscribe(topic, opts)

  @doc "Unsubscribe the caller from `topic`."
  @spec unsubscribe(binary()) :: :ok
  def unsubscribe(topic), do: endpoint().unsubscribe(topic)

  @doc "Broadcast `msg` as `event` on `topic` via the configured endpoint's PubSub."
  @spec broadcast(binary(), binary(), term()) :: :ok | {:error, term()}
  def broadcast(topic, event, msg), do: endpoint().broadcast(topic, event, msg)
end
