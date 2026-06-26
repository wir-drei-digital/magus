defmodule Magus.MCP.ToolAdapter do
  @moduledoc """
  Converts remote MCP tool definitions into the shape stored in
  `Server.cached_tools`. Annotations (`readOnlyHint` / `destructiveHint` /
  `title`) are preserved so later approval-gating needs no re-discovery.

  Also coins deterministic, LLM-safe tool names (`coin_tool_name/2`) and builds
  `ReqLLM.Tool` carrier entries (`to_reqllm_tool/3`) for the catalog/runner to
  dispatch MCP tools by their coined name.
  """

  @spec normalize_tool(map()) :: {:ok, map()} | {:error, {:invalid_tool_definition, map()}}
  def normalize_tool(%{"name" => name} = raw) when is_binary(name) and name != "" do
    {:ok,
     %{
       "name" => name,
       "description" => Map.get(raw, "description") || "",
       "input_schema" => Map.get(raw, "inputSchema") || Map.get(raw, "input_schema") || %{},
       "annotations" => Map.get(raw, "annotations") || %{}
     }}
  end

  def normalize_tool(raw) when is_map(raw), do: {:error, {:invalid_tool_definition, raw}}

  @max_coined_len 64

  @doc """
  Coin a deterministic, LLM-safe tool name `<handle>__<slug(remote_name)>`.

  Slugs map any char outside `[a-zA-Z0-9_]` to `_`, ensure a letter/underscore
  lead, and truncate the whole name to #{@max_coined_len} chars with a short
  stable hash suffix when truncation (or post-slug length) would exceed it.
  """
  @spec coin_tool_name(String.t(), String.t()) :: String.t()
  def coin_tool_name(handle, remote_name) when is_binary(handle) and is_binary(remote_name) do
    slug =
      remote_name
      |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
      |> ensure_leading_char()

    base = "#{handle}__#{slug}"

    if String.length(base) <= @max_coined_len do
      base
    else
      # 8-char stable hash of the full base; reserve "_" + 8 chars.
      hash = :crypto.hash(:sha256, base) |> Base.encode16(case: :lower) |> binary_part(0, 8)
      keep = @max_coined_len - String.length(hash) - 1
      String.slice(base, 0, keep) <> "_" <> hash
    end
  end

  defp ensure_leading_char(<<c, _::binary>> = s) when c in ?a..?z or c in ?A..?Z or c == ?_, do: s
  defp ensure_leading_char(s), do: "_" <> s

  @doc """
  Build a carrier entry (coined name + `%ReqLLM.Tool{}` + dispatch metadata) from
  a cached tool map and its server. Returns `{:error, _}` (caller skips + logs)
  when the name is empty or `ReqLLM.Tool.new/1` rejects the definition.
  """
  @spec to_reqllm_tool(map(), Magus.MCP.Server.t(), map()) ::
          {:ok,
           %{
             coined_name: String.t(),
             tool: ReqLLM.Tool.t(),
             server_id: String.t(),
             remote_name: String.t()
           }}
          | {:error, term()}
  def to_reqllm_tool(
        %{"name" => remote_name} = cached,
        %Magus.MCP.Server{} = server,
        executor_ctx
      )
      when is_binary(remote_name) and remote_name != "" do
    coined = coin_tool_name(server.handle, remote_name)
    schema = (Map.get(cached, "input_schema") || %{}) |> enforce_no_additional_properties()

    callback = build_callback(server, remote_name, executor_ctx)

    case ReqLLM.Tool.new(
           name: coined,
           description: Map.get(cached, "description") || "",
           parameter_schema: schema,
           callback: callback
         ) do
      {:ok, %ReqLLM.Tool{} = tool} ->
        {:ok, %{coined_name: coined, tool: tool, server_id: server.id, remote_name: remote_name}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def to_reqllm_tool(cached, _server, _ctx), do: {:error, {:invalid_tool_definition, cached}}

  # The ReAct runner dispatches MCP tools by name via the carrier (it does not
  # invoke this callback), but a valid callback is required for non-ReAct callers.
  #
  # `Magus.MCP.Executor` lands in a later task. The dispatch is resolved at call
  # time via `apply/3` so this module compiles cleanly (including under
  # `--warnings-as-errors`) before the Executor exists.
  @executor Magus.MCP.Executor
  defp build_callback(server, remote_name, executor_ctx) do
    fn args -> apply(@executor, :call, [server, remote_name, args, executor_ctx]) end
  end

  @doc "Recursively set additionalProperties:false on object schemas (OpenAI strict-mode parity)."
  @spec enforce_no_additional_properties(map()) :: map()
  def enforce_no_additional_properties(%{"type" => "object"} = schema) do
    schema
    |> Map.put_new("additionalProperties", false)
    |> map_properties()
  end

  def enforce_no_additional_properties(%{"properties" => _} = schema) do
    schema
    |> Map.put_new("additionalProperties", false)
    |> map_properties()
  end

  def enforce_no_additional_properties(other), do: other

  defp map_properties(%{"properties" => props} = schema) when is_map(props) do
    %{
      schema
      | "properties" => Map.new(props, fn {k, v} -> {k, enforce_no_additional_properties(v)} end)
    }
  end

  defp map_properties(schema), do: schema
end
