defmodule Magus.Chat.FolderVisibilityTest do
  @moduledoc """
  The `:kinds` argument on folder read actions filters results so each
  navigation context only sees the relevant folder kinds.
  """
  use Magus.ResourceCase, async: false

  import Magus.Generators

  describe "kinds argument filters folders" do
    test "my_folders without kinds returns all kinds" do
      user = generate(user())
      {:ok, _f} = Magus.Chat.create_folder(%{name: "f", kind: :files}, actor: user)
      {:ok, _c} = Magus.Chat.create_folder(%{name: "c", kind: :conversations}, actor: user)
      {:ok, m} = Magus.Chat.create_folder(%{name: "m", kind: :files}, actor: user)
      Magus.Chat.promote_folder_to_mixed!(m, actor: user)

      assert length(Magus.Chat.my_folders!(actor: user)) == 3
    end

    test "my_folders with kinds: [:files, :mixed] hides :conversations" do
      user = generate(user())
      {:ok, _files_folder} = Magus.Chat.create_folder(%{name: "f", kind: :files}, actor: user)

      {:ok, _conv_folder} =
        Magus.Chat.create_folder(%{name: "c", kind: :conversations}, actor: user)

      {:ok, mixed} = Magus.Chat.create_folder(%{name: "m", kind: :files}, actor: user)
      Magus.Chat.promote_folder_to_mixed!(mixed, actor: user)

      result = Magus.Chat.my_folders!(%{kinds: [:files, :mixed]}, actor: user)
      assert result |> Enum.map(& &1.kind) |> Enum.sort() == [:files, :mixed]
    end

    test "my_folders with kinds: [:conversations, :mixed] hides :files" do
      user = generate(user())
      {:ok, _files_folder} = Magus.Chat.create_folder(%{name: "f", kind: :files}, actor: user)

      {:ok, _conv_folder} =
        Magus.Chat.create_folder(%{name: "c", kind: :conversations}, actor: user)

      result = Magus.Chat.my_folders!(%{kinds: [:conversations, :mixed]}, actor: user)
      assert Enum.map(result, & &1.kind) == [:conversations]
    end
  end
end
