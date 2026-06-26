defmodule Magus.Sandbox do
  @moduledoc """
  The Sandbox domain provides code execution and development environment capabilities
  for AI agents.

  It manages:
  - Sandbox resources (persistent development environments per conversation)
  - Execution records (code runs, command executions, file operations)

  The sandbox runs Ubuntu 24.04 with Python, Node.js, Go, Ruby, and Rust
  pre-installed. Files created by execution are persisted to the Files domain.
  Sandboxes use Sprites.dev (Firecracker MicroVMs) for secure, isolated execution.
  """

  use Ash.Domain,
    otp_app: :magus

  resources do
    resource Magus.Sandbox.Sandbox do
      define :get_sandbox, action: :read, get_by: [:id]

      define :get_sandbox_by_conversation, action: :for_conversation, args: [:conversation_id]

      define :create_sandbox, action: :create, args: [:conversation_id]
      define :provision, action: :provision
      define :suspend, action: :suspend
      define :resume, action: :resume
      define :terminate, action: :terminate
      define :record_execution, action: :record_execution, args: [:duration_ms, :cost_usd]
      define :add_package, action: :add_package, args: [:package]
      define :set_service_port, action: :set_service_port
    end

    resource Magus.Sandbox.Execution do
      define :get_execution, action: :read, get_by: [:id]
      define :create_execution, action: :create
      define :start_execution, action: :start
      define :complete_execution, action: :complete
      define :fail_execution, action: :fail
      define :timeout_execution, action: :timeout
    end
  end
end
