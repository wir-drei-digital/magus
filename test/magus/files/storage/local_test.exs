defmodule Magus.Files.Storage.LocalTest do
  @moduledoc """
  Path-traversal protection for the local storage backend (magus-mw8p).
  """
  use ExUnit.Case, async: true

  alias Magus.Files.Storage.Local

  describe "full_path/1 boundary protection" do
    test "allows a normal path under the base directory" do
      full = Local.full_path("user-1/abc.png")
      assert String.ends_with?(full, "priv/static/uploads/files/user-1/abc.png")
    end

    test "rejects parent-directory traversal" do
      assert_raise ArgumentError, ~r/path traversal/, fn ->
        Local.full_path("../../etc/passwd")
      end
    end

    test "rejects a sibling directory that shares the base prefix" do
      # "<base>_evil" shares the "<base>" prefix, so the old String.starts_with?
      # check accepted it. The boundary-safe check must reject it.
      assert_raise ArgumentError, ~r/path traversal/, fn ->
        Local.full_path("../files_evil/secret")
      end
    end
  end
end
