defmodule MagusWeb.Plugs.RawBodyReader do
  @moduledoc """
  Custom body reader that caches the raw request body for webhook signature verification.

  Stripe webhook signature verification requires the exact raw body bytes.
  This plug caches the raw body in the connection's private storage so it can
  be accessed by the webhook controller after the body has been parsed.

  ## Usage

  In your endpoint.ex, configure the JSON parser to use this reader for webhook paths:

      plug Plug.Parsers,
        parsers: [:urlencoded, :multipart, :json],
        pass: ["*/*"],
        body_reader: {MagusWeb.Plugs.RawBodyReader, :read_body, []},
        json_decoder: Phoenix.json_library()

  Then in your controller:

      raw_body = conn.private[:raw_body]
  """

  @doc """
  Reads the request body and caches it in conn.private[:raw_body].

  This function is designed to be used as the `:body_reader` option in Plug.Parsers.
  """
  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        # Cache the raw body for later use (e.g., webhook signature verification)
        conn = Plug.Conn.put_private(conn, :raw_body, body)
        {:ok, body, conn}

      {:more, body, conn} ->
        # For chunked bodies, we need to accumulate
        conn = Plug.Conn.put_private(conn, :raw_body, body)
        {:more, body, conn}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
