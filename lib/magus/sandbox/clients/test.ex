defmodule Magus.Sandbox.Clients.Test do
  @moduledoc """
  Stub sandbox provider for tests. Returns :not_configured for all operations
  to prevent tests from provisioning real sandbox services.

  Used automatically in test environment via config/test.exs.
  E2E tests that need real sandboxes override the provider in their setup.
  """

  @behaviour Magus.Sandbox.Provider

  @impl true
  def configured?, do: false

  @impl true
  def create_sandbox(_opts \\ []), do: {:error, :not_configured}

  @impl true
  def destroy(_sandbox_id), do: {:error, :not_configured}

  @impl true
  def get_sandbox(_sandbox_id), do: {:error, :not_configured}

  @impl true
  def exec(_sandbox_id, _command, _opts \\ []), do: {:error, :not_configured}

  @impl true
  def read_file(_sandbox_id, _path), do: {:error, :not_configured}

  @impl true
  def write_file(_sandbox_id, _path, _content), do: {:error, :not_configured}

  @impl true
  def list_files(_sandbox_id, _path \\ "/workspace"), do: {:error, :not_configured}

  @impl true
  def ensure_directory(_sandbox_id, _path), do: {:error, :not_configured}

  @impl true
  def reset(_sandbox_id, _path), do: {:error, :not_configured}

  @impl true
  def checkpoint(_sandbox_id), do: {:error, :not_configured}

  @impl true
  def restore(_sandbox_id, _checkpoint_id), do: {:error, :not_configured}

  @impl true
  def proxy_request(_sandbox_id, _port, _request), do: {:error, :not_configured}
end
