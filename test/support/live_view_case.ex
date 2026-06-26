defmodule MagusWeb.LiveViewCase do
  @moduledoc """
  Test case for LiveView integration tests.

  This module provides helpers for testing LiveViews with authentication,
  Oban job execution, and Mox mock verification.

  ## Usage

      defmodule MagusWeb.ChatLiveTest do
        use MagusWeb.LiveViewCase, async: false

        test "user can send message", ctx do
          user = generate(user())
          conn = log_in_user(ctx.conn, user)
          {:ok, view, _html} = live(conn, ~p"/chat")
          # ... test assertions
        end
      end
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint MagusWeb.Endpoint

      use MagusWeb, :verified_routes
      use Oban.Testing, repo: Magus.Repo

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import Magus.Generators
      import Mox

      alias Magus.Chat
      alias Magus.Files
      alias Magus.Test.MockResponses

      setup :verify_on_exit!
    end
  end

  setup tags do
    Magus.DataCase.setup_sandbox(tags)

    # Set Mox to global mode so that Oban workers (which run in separate processes)
    # can access mock expectations. Passing the tags makes Mox raise if a test
    # module overrides async: true, which would leak global mode into
    # concurrently running tests.
    Mox.set_mox_global(tags)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Log in a user for LiveView testing.

  This sets up the session so that `AshAuthentication.Phoenix.LiveSession`
  can find and load the user during the LiveView mount.

  Uses AshAuthentication.Plug.Helpers.store_in_session/2 to properly
  store the user token in the session.

  ## Example

      user = generate(user())
      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/chat")
  """
  def log_in_user(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  @doc """
  Log in the user with a specific workspace persisted as their
  `current_workspace_id`. The workbench reads from the user record,
  not the Plug session, so tests must persist the selection.
  """
  def log_in_user_with_workspace(conn, user, workspace) do
    {:ok, user} = Magus.Accounts.select_workspace(user, workspace.id, actor: user)
    log_in_user(conn, user)
  end

  @doc """
  Enable the desktop tab bar for a user (sets `ui_preferences["tabs_enabled"] = true`).
  WorkbenchLive reads this at mount, so tests that exercise tab-bar UI must set
  it before calling `log_in_user/2`.
  """
  def enable_tabs(user) do
    prefs = Map.put(user.ui_preferences || %{}, "tabs_enabled", true)
    {:ok, user} = Magus.Accounts.update_ui_preferences(user, prefs, actor: user)
    user
  end

  @doc """
  Register a new user and log them in for testing.

  ## Example

      %{conn: conn, user: user} = register_and_log_in_user(%{conn: conn})
      {:ok, view, _html} = live(conn, ~p"/chat")
  """
  def register_and_log_in_user(%{conn: conn}) do
    user = Magus.Generators.generate(Magus.Generators.user())
    %{conn: log_in_user(conn, user), user: user}
  end
end
