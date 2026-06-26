defmodule MagusWeb.Plugs.RawBodyParser do
  @moduledoc """
  Plug parser that preserves the raw request body.

  Required for webhook signature verification where the exact bytes
  of the request body must be used for HMAC or other signature checks.

  The raw body is stored in `conn.private[:raw_body]`.

  ## Usage in Router

  ```elixir
  pipeline :webhook do
    plug Plug.Parsers,
      parsers: [MagusWeb.Plugs.RawBodyParser],
      pass: ["*/*"]
  end
  ```
  """

  @behaviour Plug.Parsers

  @impl true
  def init(opts), do: opts

  @impl true
  def parse(conn, "application", "json", _headers, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        conn = Plug.Conn.put_private(conn, :raw_body, body)

        case Jason.decode(body) do
          {:ok, decoded} ->
            {:ok, decoded, conn}

          {:error, _} ->
            # Store raw body but return empty params if JSON is invalid
            {:ok, %{}, conn}
        end

      {:more, _data, conn} ->
        {:error, :too_large, conn}

      {:error, :timeout} ->
        raise Plug.TimeoutError

      {:error, _} ->
        raise Plug.BadRequestError
    end
  end

  def parse(conn, "application", subtype, _headers, opts)
      when subtype in ["x-www-form-urlencoded"] do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        conn = Plug.Conn.put_private(conn, :raw_body, body)
        {:ok, Plug.Conn.Query.decode(body), conn}

      {:more, _data, conn} ->
        {:error, :too_large, conn}

      {:error, :timeout} ->
        raise Plug.TimeoutError

      {:error, _} ->
        raise Plug.BadRequestError
    end
  end

  def parse(conn, _type, _subtype, _headers, _opts) do
    {:next, conn}
  end
end
