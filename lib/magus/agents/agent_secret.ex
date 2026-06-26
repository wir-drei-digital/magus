defmodule Magus.Agents.AgentSecret do
  @moduledoc """
  Per-agent encrypted secrets for injecting sensitive values into agent contexts.

  Secrets are encrypted at rest using AES-256-GCM via Cloak. The `value`
  attribute is transparently decrypted when loaded from the database.

  ## Scopes

  - `:sandbox_env` — Injected as environment variables into sandboxed code execution
  - `:tool_config` — Used to configure specific tool integrations

  ## Example

      {:ok, secret} = Magus.Agents.create_agent_secret(%{
        custom_agent_id: agent.id,
        key: "GITHUB_TOKEN",
        value: "ghp_abc123",
        scope: :sandbox_env
      }, actor: user)
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshTypescript.Resource]

  postgres do
    table "agent_secrets"
    repo Magus.Repo

    references do
      reference :custom_agent, on_delete: :delete
    end
  end

  typescript do
    type_name "AgentSecret"
  end

  actions do
    read :read do
      primary? true
    end

    read :for_agent do
      argument :custom_agent_id, :uuid, allow_nil?: false
      filter expr(custom_agent_id == ^arg(:custom_agent_id))
    end

    read :sandbox_env_for_agent do
      argument :custom_agent_id, :uuid, allow_nil?: false
      filter expr(custom_agent_id == ^arg(:custom_agent_id) and scope == :sandbox_env)
    end

    create :create do
      accept [:key, :value, :scope, :description, :custom_agent_id]

      validate match(:key, ~r/^[A-Za-z_][A-Za-z0-9_]*$/),
        message:
          "must be a valid environment variable name (letters, digits, underscores, cannot start with a digit)"
    end

    update :update do
      accept [:value, :description]
    end

    destroy :destroy do
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if relates_to_actor_via([:custom_agent, :user])
    end

    policy action_type(:create) do
      authorize_if Magus.Agents.AgentSecret.Checks.AgentBelongsToActor
    end

    policy action_type([:update, :destroy]) do
      authorize_if relates_to_actor_via([:custom_agent, :user])
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :key, :string do
      allow_nil? false
      public? true
      description "Environment variable name or configuration key (e.g. 'GITHUB_TOKEN')"
    end

    attribute :value, Magus.Agents.AgentSecret.EncryptedString do
      allow_nil? false
      public? true
      description "Encrypted secret value — decrypted transparently on load"
    end

    attribute :scope, :atom do
      allow_nil? false
      public? true
      default :sandbox_env
      constraints one_of: [:sandbox_env, :tool_config]

      description "Where this secret is used: :sandbox_env for code execution, :tool_config for tool settings"
    end

    attribute :description, :string do
      allow_nil? true
      public? true
      description "Human-readable description of what this secret is for"
    end

    create_timestamp :inserted_at, public?: true
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :custom_agent, Magus.Agents.CustomAgent do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_key_per_agent, [:custom_agent_id, :key]
  end
end
