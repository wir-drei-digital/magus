defmodule Magus.MCP.RegistryEntry do
  @moduledoc """
  Normalized, in-memory view of one entry from the official MCP registry
  (`registry.modelcontextprotocol.io`). Built by `Magus.MCP.RegistryEntry.from_raw/1`
  from a raw server object and used by the browse UI and `Magus.MCP.Importer`.

  Only **remote** servers (a non-empty `remotes` array with transport
  `streamable-http` or `sse`) are representable; `packages`-only (stdio/npm/pypi)
  entries return `:skip` and are never shown — Magus is a remote-HTTP MCP client
  with no stdio transport.
  """

  @enforce_keys [:registry_name, :display_name, :transport, :endpoint_url]
  defstruct registry_name: nil,
            display_name: nil,
            description: nil,
            version: nil,
            repository_url: nil,
            transport: nil,
            endpoint_url: nil,
            auth_type: :none,
            # [%{name, template, vars: [String.t()], secret: bool, required: bool, description}]
            required_headers: [],
            status: "active"

  @type t :: %__MODULE__{}

  @doc """
  Normalizes one raw registry server object into a `%RegistryEntry{}`.

  Returns `:skip` when the entry is not an importable remote server (no usable
  `remotes`, or a non-active status). The registry has wrapped the server fields
  under a `"server"` key in some API revisions and inlined them in others, so
  both shapes are accepted.
  """
  @spec from_raw(map()) :: {:ok, t()} | :skip
  def from_raw(raw) when is_map(raw) do
    {srv, status} = unwrap(raw)

    with true <- status in ["active", nil],
         {:ok, remote} <- pick_remote(srv["remotes"]),
         url when is_binary(url) and url != "" <- remote["url"] do
      name = srv["name"]

      {:ok,
       %__MODULE__{
         registry_name: name,
         display_name: display_name(srv["title"], name),
         description: srv["description"],
         version: srv["version"],
         repository_url: get_in(srv, ["repository", "url"]),
         transport: transport(remote["type"]),
         endpoint_url: url,
         required_headers: normalize_headers(remote["headers"]),
         auth_type: infer_auth_type(remote["headers"]),
         status: status || "active"
       }}
    else
      _ -> :skip
    end
  end

  def from_raw(_), do: :skip

  # Some API revisions nest the server under "server" and the registry metadata
  # (incl. status) under "_meta"; others inline everything. Handle both.
  defp unwrap(raw) do
    srv = if is_map(raw["server"]), do: raw["server"], else: raw
    meta = raw["_meta"] || srv["_meta"] || %{}
    status = get_in(meta, ["io.modelcontextprotocol.registry/official", "status"])
    {srv, status}
  end

  # Prefer streamable-http over the legacy SSE transport.
  defp pick_remote(remotes) when is_list(remotes) and remotes != [] do
    streamable = Enum.find(remotes, &(transport(&1["type"]) == :streamable_http))
    sse = Enum.find(remotes, &(transport(&1["type"]) == :sse))

    case streamable || sse do
      nil -> :skip
      remote -> {:ok, remote}
    end
  end

  defp pick_remote(_), do: :skip

  defp transport("streamable-http"), do: :streamable_http
  defp transport("streamable_http"), do: :streamable_http
  defp transport("http"), do: :streamable_http
  defp transport("sse"), do: :sse
  defp transport(_), do: :unknown

  # Auth inference (spec §7.4), driven by the chosen remote's required headers:
  #
  #   * A required header whose `value` template carries `{placeholder}` token(s)
  #     means the user can supply that secret → `:static_header`. Bias toward the
  #     fillable path: if ANY required header is user-fillable, `:static_header`.
  #   * Required header(s) exist but NONE carry a `{placeholder}` token (the
  #     credential is injected by an auth flow, not user-typed) → `:oauth`, so the
  #     UI offers the "Connect" OAuth flow rather than a dead secret form.
  #   * No required headers → `:none` (a server that still needs OAuth is covered
  #     by the executor's connect-time 401→OAuth fallback).
  #
  # The official registry shape (§5) carries no explicit OAuth/auth-type field on
  # remotes — only header `name`/`value`/`isRequired`/`isSecret` — so the
  # placeholder heuristic above is the signal; we do not invent a field.
  defp infer_auth_type(headers) when is_list(headers) do
    required = Enum.filter(headers, &(&1["isRequired"] == true))

    cond do
      required == [] -> :none
      Enum.any?(required, &header_has_placeholder?/1) -> :static_header
      true -> :oauth
    end
  end

  defp infer_auth_type(_), do: :none

  defp header_has_placeholder?(header), do: extract_vars(header["value"] || "") != []

  defp normalize_headers(headers) when is_list(headers) do
    Enum.map(headers, fn h ->
      template = h["value"] || ""

      %{
        name: h["name"],
        template: template,
        vars: extract_vars(template),
        secret: h["isSecret"] == true,
        required: h["isRequired"] == true,
        description: h["description"]
      }
    end)
  end

  defp normalize_headers(_), do: []

  # `"Bearer {smithery_api_key}"` → ["smithery_api_key"]
  defp extract_vars(template) when is_binary(template) do
    Regex.scan(~r/\{([^}]+)\}/, template) |> Enum.map(fn [_, v] -> v end) |> Enum.uniq()
  end

  defp extract_vars(_), do: []

  # Prefer the registry's human `title` (e.g. "inference.sh", "GitHub"); the
  # reverse-DNS `name` is an id whose last segment is often the generic "mcp",
  # which is why so many entries otherwise render as "Mcp".
  defp display_name(title, name) do
    case clean_title(title) do
      nil -> derive_from_name(name)
      label -> label
    end
  end

  defp clean_title(title) when is_binary(title) do
    case String.trim(title) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp clean_title(_), do: nil

  # Fallback: derive a label from the reverse-DNS name's last segment
  # (`ai.smithery/smithery-ai-github` → "Smithery Ai Github"), dropping the
  # generic "mcp"/"server" tokens so `…/docs-mcp` → "Docs" rather than "Docs Mcp".
  defp derive_from_name(name) when is_binary(name) do
    tokens =
      name
      |> String.split("/")
      |> List.last()
      |> String.replace(~r/[-_.]+/, " ")
      |> String.split(" ", trim: true)

    meaningful = Enum.reject(tokens, &(String.downcase(&1) in ["mcp", "server"]))

    # If every token was generic (e.g. just "mcp"), keep them rather than blank.
    chosen = if meaningful == [], do: tokens, else: meaningful

    case Enum.map_join(chosen, " ", &capitalize_word/1) do
      "" -> name
      label -> label
    end
  end

  defp derive_from_name(_), do: "MCP Server"

  defp capitalize_word(word), do: String.capitalize(word)
end
