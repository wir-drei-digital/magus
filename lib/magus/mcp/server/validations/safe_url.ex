defmodule Magus.MCP.Server.Validations.SafeUrl do
  @moduledoc "Rejects MCP server URLs that fail SSRF validation."
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :url) do
      nil ->
        :ok

      url ->
        case Magus.MCP.SafeUrl.validate(url) do
          :ok -> :ok
          {:error, msg} -> {:error, field: :url, message: msg}
        end
    end
  end
end
