defmodule Magus.Sandbox.Execution do
  @moduledoc """
  Record of a code execution in a sandbox.

  Tracks the code, output, status, duration, and cost of each execution
  for debugging, billing, and audit purposes.
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Sandbox,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "sandbox_executions"
    repo Magus.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:code, :command, :description, :sandbox_id, :message_id, :type]
      change set_attribute(:status, :pending)
    end

    update :start do
      accept []
      change set_attribute(:status, :running)
    end

    update :complete do
      accept [:stdout, :stderr, :exit_code, :duration_ms, :estimated_cost_usd, :files_created]
      change set_attribute(:status, :completed)
    end

    update :fail do
      accept [:stdout, :stderr, :exit_code, :duration_ms, :error_type]
      change set_attribute(:status, :failed)
    end

    update :timeout do
      accept [:stdout, :stderr, :duration_ms]
      change set_attribute(:status, :timeout)
      change set_attribute(:error_type, :timeout)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(sandbox.conversation.user_id == ^actor(:id))
      authorize_if Magus.Checks.IsAdmin
    end

    policy action_type(:create) do
      authorize_if Magus.Sandbox.Checks.OwnsSandbox
      authorize_if Magus.Checks.IsAdmin
    end

    policy action_type(:update) do
      authorize_if expr(sandbox.conversation.user_id == ^actor(:id))
      authorize_if Magus.Checks.IsAdmin
    end

    policy action_type(:destroy) do
      authorize_if expr(sandbox.conversation.user_id == ^actor(:id))
      authorize_if Magus.Checks.IsAdmin
    end
  end

  attributes do
    uuid_v7_primary_key :id

    # Execution type
    attribute :type, :atom do
      constraints one_of: [:python_code, :command, :file_op, :service]
      default :python_code
      allow_nil? false
      public? true
    end

    # Code input
    attribute :code, :string, constraints: [max_length: 51_200], public?: true
    attribute :command, :string, public?: true
    attribute :description, :string, public?: true

    # Execution output
    attribute :stdout, :string, public?: true
    attribute :stderr, :string, public?: true
    attribute :exit_code, :integer, public?: true
    attribute :duration_ms, :integer, public?: true
    attribute :estimated_cost_usd, :decimal, public?: true
    attribute :files_created, {:array, :map}, default: [], public?: true

    # Error tracking
    attribute :error_type, :atom do
      constraints one_of: [:timeout, :oom, :syntax_error, :runtime_error, :validation_error]
      public? true
    end

    # Status tracking
    attribute :status, :atom do
      constraints one_of: [:pending, :running, :completed, :failed, :timeout]
      default :pending
      allow_nil? false
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :sandbox, Magus.Sandbox.Sandbox, allow_nil?: false
    belongs_to :message, Magus.Chat.Message
  end
end
