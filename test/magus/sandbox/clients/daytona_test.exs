defmodule Magus.Sandbox.Clients.DaytonaTest do
  @moduledoc """
  HTTP-stubbed tests for the Daytona control-plane client.

  Daytona auto-stops idle sandboxes, so `checkpoint/1` (our suspend) routinely
  races the platform: POST /stop returns 400 "Sandbox is not in a stoppable
  state" when the box is already stopped. These tests lock in that the client
  resolves such 400s from the sandbox's actual state instead of failing.
  """
  use ExUnit.Case, async: true

  alias Magus.Sandbox.Clients.Daytona

  @unstoppable %{
    "error" => "Bad Request",
    "message" => "Sandbox is not in a stoppable state",
    "statusCode" => 400
  }

  defp stub_stop_then_state(stop_status, stop_body, states) do
    remaining = start_supervised!({Agent, fn -> states end})

    Req.Test.stub(Daytona, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/api/sandbox/sb-1/stop"} ->
          conn
          |> Plug.Conn.put_status(stop_status)
          |> Req.Test.json(stop_body)

        {"GET", "/api/sandbox/sb-1"} ->
          state = Agent.get_and_update(remaining, fn [head | tail] -> {head, tail} end)
          Req.Test.json(conn, %{"id" => "sb-1", "state" => state})
      end
    end)
  end

  describe "checkpoint/1" do
    test "stop accepted: polls until the sandbox reports stopped" do
      stub_stop_then_state(200, %{}, ["stopped"])

      assert :ok = Daytona.checkpoint("sb-1")
    end

    test "unstoppable 400 with sandbox already stopped counts as suspended" do
      stub_stop_then_state(400, @unstoppable, ["stopped"])

      assert :ok = Daytona.checkpoint("sb-1")
    end

    test "unstoppable 400 with sandbox archived counts as suspended" do
      stub_stop_then_state(400, @unstoppable, ["archived"])

      assert :ok = Daytona.checkpoint("sb-1")
    end

    test "unstoppable 400 while still stopping polls through to stopped" do
      stub_stop_then_state(400, @unstoppable, ["stopping", "stopped"])

      assert :ok = Daytona.checkpoint("sb-1")
    end

    test "unstoppable 400 in a non-suspendable state propagates the API error" do
      stub_stop_then_state(400, @unstoppable, ["error"])

      assert {:error, {:api_error, 400, @unstoppable}} = Daytona.checkpoint("sb-1")
    end

    test "unstoppable 400 for a destroyed sandbox returns not_found" do
      Req.Test.stub(Daytona, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/api/sandbox/sb-1/stop"} ->
            conn
            |> Plug.Conn.put_status(400)
            |> Req.Test.json(@unstoppable)

          {"GET", "/api/sandbox/sb-1"} ->
            conn
            |> Plug.Conn.put_status(404)
            |> Req.Test.json(%{"statusCode" => 404})
        end
      end)

      assert {:error, :not_found} = Daytona.checkpoint("sb-1")
    end

    test "non-400 API errors propagate unchanged" do
      Req.Test.stub(Daytona, fn conn ->
        conn
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{"statusCode" => 500})
      end)

      assert {:error, {:api_error, 500, %{"statusCode" => 500}}} = Daytona.checkpoint("sb-1")
    end
  end
end
