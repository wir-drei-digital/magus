defmodule MagusWeb.ChannelCase do
  @moduledoc """
  Test case for Phoenix Channel tests (MagusWeb.UserSocket and channels).

  Mirrors `MagusWeb.ConnCase`: sets up the SQL sandbox and imports
  `Phoenix.ChannelTest` conveniences against the app endpoint.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint MagusWeb.Endpoint

      import Phoenix.ChannelTest
      import MagusWeb.ChannelCase
    end
  end

  setup tags do
    Magus.DataCase.setup_sandbox(tags)
    :ok
  end
end
