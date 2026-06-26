defmodule MagusWeb.HealthController do
  @moduledoc """
  Liveness/readiness probe used by Fly.io health checks and ops dashboards.

  Returns 200 with a JSON status payload that includes a FalkorDB
  liveness check. The endpoint itself always returns 200 even when
  FalkorDB is down so the application's other endpoints can still serve
  traffic; the FalkorDB key is marked accordingly.
  """

  use MagusWeb, :controller

  @falkordb_ping_timeout_ms 1_000

  def index(conn, _params) do
    json(conn, %{
      status: "ok",
      falkordb: falkordb_health(),
      checked_at: DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  defp falkordb_health do
    case Magus.Graph.Connection.command(["PING"], timeout: @falkordb_ping_timeout_ms) do
      {:ok, "PONG"} -> "ok"
      _ -> "unavailable"
    end
  rescue
    _ -> "unavailable"
  catch
    :exit, _ -> "unavailable"
    _, _ -> "unavailable"
  end
end
