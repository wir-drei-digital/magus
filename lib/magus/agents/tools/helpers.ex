defmodule Magus.Agents.Tools.Helpers do
  @moduledoc """
  Shared helper functions for AI agent tools.

  Provides common functionality used across memory, job, and other tool modules
  to reduce code duplication and ensure consistent behavior.

  ## Tool Progress Events

  Tools can emit progress events to provide real-time feedback in the UI.
  The LLM strategy passes event metadata in the tool context.

  Use `Magus.Agents.Signals.emit_tool_progress/3` to emit progress:

      def run(params, context) do
        # Emit progress at key points
        Signals.emit_tool_progress(context, :searching, %{query: params.query})

        # Do work...
        results = search(params.query)

        # Emit more progress
        Signals.emit_tool_progress(context, :found_results, %{count: length(results)})

        {:ok, %{results: results}}
      end

  Common progress types:
  - `:searching` - Starting a search operation
  - `:fetching` - Fetching remote content
  - `:processing` - Processing data
  - `:result_found` - Found a search result
  - `:page_fetched` - Fetched a web page
  - `:creating` - Creating a resource
  - `:updating` - Updating a resource

  The context contains these metadata fields (prefixed with `__`):
  - `__conversation_id__` - The conversation this tool is running in
  - `__event_id__` - Unique ID for this tool execution event
  - `__tool_name__` - Name of the tool being executed
  """

  @doc """
  Extracts a value from the context map, handling both atom and string keys.

  ## Examples

      iex> get_context_value(%{user_id: "123"}, :user_id)
      "123"

      iex> get_context_value(%{"user_id" => "123"}, :user_id)
      "123"

      iex> get_context_value(%{}, :user_id)
      nil
  """
  @spec get_context_value(map(), atom()) :: any()
  def get_context_value(context, key) when is_map(context) do
    Map.get(context, key) || Map.get(context, to_string(key))
  end

  def get_context_value(_, _), do: nil

  @doc """
  Extracts human-readable error messages from Ash errors.

  Handles various Ash error types including Invalid, Forbidden, NotFound,
  and InvalidAttribute errors.

  ## Examples

      iex> extract_error_message(%Ash.Error.Invalid{errors: [%{message: "is required"}]})
      "is required"
  """
  @spec extract_error_message(any()) :: String.t()
  def extract_error_message(%Ash.Error.Invalid{} = error) do
    error.errors
    |> Enum.map(&extract_single_error/1)
    |> Enum.join("; ")
  end

  def extract_error_message(%Ash.Error.Forbidden{} = error) do
    "Authorization failed: " <>
      (error.errors
       |> Enum.map(&extract_single_error/1)
       |> Enum.join("; "))
  end

  def extract_error_message(error), do: inspect(error)

  defp extract_single_error(%Ash.Error.Query.NotFound{resource: resource}) do
    "#{inspect(resource)} not found"
  end

  # Its default Exception.message embeds the entire inspected Ecto query
  # (`Invalid filter value ... supplied in #Ecto.Query<...>`), which is
  # useless noise for the LLM. Render just the offending value.
  defp extract_single_error(%Ash.Error.Query.InvalidFilterValue{value: value}) do
    "invalid filter value #{inspect(value)} (expected a valid id)"
  end

  defp extract_single_error(%Ash.Error.Changes.InvalidAttribute{field: field, message: message})
       when is_binary(message) do
    "#{field}: #{message}"
  end

  defp extract_single_error(%{message: message}) when is_binary(message), do: message

  defp extract_single_error(error) when is_struct(error) do
    if function_exported?(error.__struct__, :message, 1) do
      try do
        Exception.message(error)
      rescue
        _ -> inspect(error)
      end
    else
      inspect(error)
    end
  end

  defp extract_single_error(error), do: inspect(error)

  @doc """
  Returns the AI agent actor for authorization.
  """
  @spec ai_actor() :: %Magus.Agents.Support.AiAgent{}
  def ai_actor, do: %Magus.Agents.Support.AiAgent{}

  @doc """
  Formats an Ash error into an LLM-facing message that explains what
  went wrong AND tells the LLM what to do next.

  Use this instead of `"Failed to X: \#{inspect(err)}"` — `inspect`
  leaks Ash internals (changesets, policy structs, stack traces) into
  the LLM's context, which is both noisy and confusing.

  ## Examples

      iex> err = %Ash.Error.Query.NotFound{}
      iex> tool_error("read page", err, "Verify the page_id with read_brain list_pages.")
      "Failed to read page: Magus.Brain.Page not found. Verify the page_id with read_brain list_pages."
  """
  @spec tool_error(String.t(), any(), String.t() | nil) :: String.t()
  def tool_error(operation, error, hint \\ nil) do
    message = extract_error_message(error)
    base = "Failed to #{operation}: #{message}"
    if hint, do: base <> ". " <> hint, else: base <> "."
  end

  @doc """
  Gets a parameter value, handling both atom and string keys.
  LLMs send string keys, but Jido schemas use atom keys.

  ## Examples

      iex> get_param(%{query: "test"}, :query)
      "test"

      iex> get_param(%{"query" => "test"}, :query)
      "test"

      iex> get_param(%{}, :query, "default")
      "default"
  """
  @spec get_param(map(), atom(), any()) :: any()
  def get_param(params, key, default \\ nil) when is_map(params) and is_atom(key) do
    case Map.get(params, key) do
      nil -> Map.get(params, to_string(key), default)
      value -> value
    end
  end

  @doc """
  Reads an integer param, tolerating LLM format drift.

  LLMs routinely emit numbers as strings (`"20"`) or floats (`20.0`); those slip
  past a plain `get_param(...) || default` (a non-empty string is truthy) and
  then blow up integer-only callees like `Enum.take/2`. Numeric strings and
  floats are coerced to an integer; `nil`, blanks, and anything unparseable fall
  back to `default`.
  """
  @spec get_int_param(map(), atom(), integer()) :: integer()
  def get_int_param(params, key, default) when is_atom(key) and is_integer(default) do
    case get_param(params, key) do
      n when is_integer(n) ->
        n

      n when is_float(n) ->
        trunc(n)

      n when is_binary(n) ->
        case Integer.parse(String.trim(n)) do
          {i, _rest} -> i
          :error -> default
        end

      _ ->
        default
    end
  end

  @doc """
  Drops blank or null-ish string values for the given keys (atom AND string
  forms).

  LLMs routinely send `""` for id/reference params they mean to omit
  (`page_id: ""`), and weaker models emit the literal strings `"null"` /
  `"nil"` for JSON null (`parent_page_id: "null"` meaning "move to root").
  A blank id slips past `is_nil`/truthiness guards and ends up in an Ash
  filter (`id == ^""`), which raises InvalidFilterValue; a literal "null"
  becomes a failing id lookup. Deleting the key restores the intended
  "absent" semantics, so resolution falls back (pane context, title lookup,
  root) or fails with the tool's own actionable message.

  Only pass REFERENCE keys (ids, lookup titles): blank is meaningful for
  content params like `new_str` (deletion) or `body`.
  """
  @spec nilify_blank_params(map(), [atom()]) :: map()
  def nilify_blank_params(params, keys) when is_map(params) and is_list(keys) do
    Enum.reduce(keys, params, fn key, acc ->
      [key, to_string(key)]
      |> Enum.reduce(acc, fn k, inner ->
        case Map.get(inner, k) do
          value when is_binary(value) ->
            if String.trim(value) == "" or String.downcase(String.trim(value)) in ~w(null nil),
              do: Map.delete(inner, k),
              else: inner

          _ ->
            inner
        end
      end)
    end)
  end

  @doc """
  Reads an OPTIONAL integer param: coerces LLM format drift (numeric
  strings, floats) like `get_int_param/3`, but preserves absence — returns
  nil when the param is missing, nil, or unparseable.

  Use for params where nil is meaningful (e.g. `start_line`/`end_line`
  select line-range mode only when present); `get_int_param/3` is for
  params with a numeric default.
  """
  @spec get_optional_int_param(map(), atom()) :: integer() | nil
  def get_optional_int_param(params, key) when is_atom(key) do
    case get_param(params, key) do
      n when is_integer(n) ->
        n

      n when is_float(n) ->
        trunc(n)

      n when is_binary(n) ->
        case Integer.parse(String.trim(n)) do
          {i, _rest} -> i
          :error -> nil
        end

      _ ->
        nil
    end
  end

  @doc """
  Reads a boolean flag param, tolerating LLM format drift: `true` and the
  string `"true"` count as set; everything else (false, "false", nil,
  garbage) is false.
  """
  @spec flag_param?(map(), atom()) :: boolean()
  def flag_param?(params, key) when is_atom(key) do
    get_param(params, key) in [true, "true"]
  end

  @doc """
  Fix double-JSON-encoded content from LLMs.

  Some LLM providers double-encode tool call arguments, turning actual newlines
  into literal two-char `\\n` and single backslashes into `\\\\`. This is
  especially common with LaTeX and other backslash-heavy content.

  Detection heuristic: if the content has >= 3 literal `\\n` sequences but
  at most 1 actual newline character, it's treated as double-encoded.

  Uses character-by-character parsing to correctly handle ambiguous sequences
  like `\\\\n` (escaped backslash + literal n) vs `\\n` (escaped newline).
  """
  @spec maybe_unescape_content(binary()) :: binary()
  def maybe_unescape_content(content) when is_binary(content) do
    if appears_double_escaped?(content) do
      unescape_json_escapes(content, [])
    else
      content
    end
  end

  def maybe_unescape_content(content), do: content

  defp appears_double_escaped?(content) do
    literal_escapes = length(String.split(content, "\\n")) - 1
    real_newlines = length(String.split(content, "\n")) - 1

    literal_escapes >= 3 and real_newlines <= 1
  end

  # Character-by-character JSON string unescape. Pattern order matters:
  # \\\\ must match before \\n so that \\n (escaped backslash + n) is correctly
  # parsed as single backslash followed by literal n, not as escaped newline.
  defp unescape_json_escapes(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()
  defp unescape_json_escapes("\\\\" <> rest, acc), do: unescape_json_escapes(rest, ["\\" | acc])
  defp unescape_json_escapes("\\n" <> rest, acc), do: unescape_json_escapes(rest, ["\n" | acc])
  defp unescape_json_escapes("\\t" <> rest, acc), do: unescape_json_escapes(rest, ["\t" | acc])
  defp unescape_json_escapes("\\r" <> rest, acc), do: unescape_json_escapes(rest, ["\r" | acc])

  defp unescape_json_escapes(<<c, rest::binary>>, acc),
    do: unescape_json_escapes(rest, [<<c>> | acc])

  @doc """
  Builds a streaming callback for sandbox tools that emits step progress events.

  Returns a function `fn {_stream, chunk} -> ... end` suitable for `on_output` callbacks,
  or `nil` if the context lacks required event metadata.
  """
  @spec build_step_streaming_callback(map(), non_neg_integer()) :: (tuple() -> :ok | :error) | nil
  def build_step_streaming_callback(context, step_index) when is_map(context) do
    alias Magus.Agents.Signals

    with {:ok, _} <- fetch_context_field(context, :__conversation_id__),
         {:ok, _} <- fetch_context_field(context, :__event_id__),
         {:ok, _} <- fetch_context_field(context, :__tool_name__) do
      fn {_stream, chunk} ->
        Signals.emit_tool_step_progress(context, step_index, chunk, :append)
      end
    else
      _ -> nil
    end
  end

  @doc """
  Fetches a context field, returning `{:ok, value}` or `:error` if nil/missing.
  """
  @spec fetch_context_field(map(), atom()) :: {:ok, any()} | :error
  def fetch_context_field(context, key) when is_map(context) do
    case Map.get(context, key) do
      nil -> :error
      value -> {:ok, value}
    end
  end

  @doc """
  Counts the number of lines in a string.
  """
  @spec count_lines(String.t()) :: pos_integer()
  def count_lines(content), do: length(String.split(content, "\n"))

  @doc """
  Validates that required context values are present.
  Returns {:ok, context_map} or {:error, message}.

  ## Examples

      iex> validate_context(%{user_id: "123", conversation_id: "456"}, [:user_id, :conversation_id])
      {:ok, %{user_id: "123", conversation_id: "456"}}

      iex> validate_context(%{user_id: "123"}, [:user_id, :conversation_id])
      {:error, "Missing required context (conversation_id)"}
  """
  @spec validate_context(map(), [atom()]) :: {:ok, map()} | {:error, String.t()}
  def validate_context(context, required_keys) do
    extracted =
      Enum.reduce(required_keys, %{}, fn key, acc ->
        Map.put(acc, key, get_context_value(context, key))
      end)

    missing =
      Enum.filter(required_keys, fn key ->
        is_nil(Map.get(extracted, key))
      end)

    case missing do
      [] -> {:ok, extracted}
      keys -> {:error, "Missing required context (#{Enum.join(keys, ", ")})"}
    end
  end
end
