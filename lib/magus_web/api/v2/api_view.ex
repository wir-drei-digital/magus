defmodule MagusWeb.Api.V2.ApiView do
  @moduledoc """
  Consistent JSON shapes for v2 controllers.

  * `data/1` wraps a record or list as `{"data": ...}`.
  * `error/3` wraps an error as `{"error": {"code": ..., "message": ..., "details": ...}}`.
  """

  def data(payload), do: %{data: payload}

  def error(code, message, details \\ nil) do
    body = %{code: code, message: message}
    body = if details, do: Map.put(body, :details, details), else: body
    %{error: body}
  end
end
