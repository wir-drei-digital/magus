defmodule Magus.MCP.Client do
  @moduledoc """
  The single funnel to the `anubis_mcp` client API. All `Anubis.Client.*` calls
  go through here so the rest of the system depends on Magus shapes, not the
  third-party response structs (the wrap-third-party rule).
  """

  @doc "Lists tools on a started client, returning raw tool-def maps."
  @spec list_tools(GenServer.server()) :: {:ok, [map()]} | {:error, term()}
  def list_tools(client), do: normalize_tools(Anubis.Client.list_tools(client))

  @doc "Calls a tool on a started client, returning the result payload."
  @spec call_tool(GenServer.server(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def call_tool(client, name, args) when is_binary(name) and is_map(args) do
    normalize_result(Anubis.Client.call_tool(client, name, args))
  end

  @doc false
  @spec normalize_tools({:ok, term()} | {:error, term()}) :: {:ok, [map()]} | {:error, term()}
  def normalize_tools({:ok, response}) do
    case result_payload(response) do
      %{"tools" => tools} when is_list(tools) -> {:ok, tools}
      other -> {:error, {:unexpected_tools_response, other}}
    end
  end

  def normalize_tools({:error, _} = err), do: err

  @doc false
  @spec normalize_result({:ok, term()} | {:error, term()}) :: {:ok, term()} | {:error, term()}
  def normalize_result({:ok, response}), do: {:ok, result_payload(response)}
  def normalize_result({:error, _} = err), do: err

  # Tolerate both the %Anubis.MCP.Response{} struct and a plain map with :result.
  defp result_payload(%{result: result}), do: result
  defp result_payload(%{"result" => result}), do: result
  defp result_payload(other), do: other
end
