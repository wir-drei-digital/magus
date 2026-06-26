defmodule Magus.Jido do
  @moduledoc """
  Jido instance for Magus application.

  Provides the main Jido execution environment for running agents and actions.
  """

  # Storage is configured per-InstanceManager in application.ex
  # (Jido's `use` macro doesn't resolve aliases for compile-time storage option)
  use Jido, otp_app: :magus
end
