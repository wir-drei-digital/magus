defmodule Magus.Sandbox.Sandbox.Changes.UpdateWorkspaceFilesTest do
  use Magus.DataCase, async: true

  alias Magus.Sandbox
  alias Magus.Chat

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp create_user do
    {:ok, user} =
      Magus.Accounts.User
      |> Ash.Changeset.for_create(:register_with_password, %{
        email: "test-#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!",
        password_confirmation: "ValidPassword123!",
        name: "Test User",
        accepted_terms: true,
        accepted_age_requirement: true
      })
      |> Ash.create(authorize?: false)

    user
  end

  defp create_sandbox do
    user = create_user()
    {:ok, conv} = Chat.create_conversation(%{title: "t"}, actor: user)
    {:ok, sandbox} = Sandbox.create_sandbox(conv.id, authorize?: false)
    sandbox
  end

  defp record_with_files(sandbox, files) do
    Sandbox.record_execution(
      sandbox,
      100,
      Decimal.new("0.001"),
      %{workspace_files: files},
      authorize?: false
    )
  end

  # ---------------------------------------------------------------------------
  # Tests — UpdateWorkspaceFiles via record_execution action
  # ---------------------------------------------------------------------------

  describe "UpdateWorkspaceFiles change (via record_execution)" do
    test "stores normalized workspace_files with string keys" do
      sandbox = create_sandbox()

      {:ok, updated} =
        record_with_files(sandbox, [
          %{"path" => "main.py", "size" => 256}
        ])

      assert [%{"path" => "main.py", "size" => 256}] = updated.workspace_files
    end

    test "handles files with string keys in input" do
      sandbox = create_sandbox()

      {:ok, updated} =
        record_with_files(sandbox, [
          %{"path" => "app.py", "size" => 512}
        ])

      assert [%{"path" => "app.py", "size" => 512}] = updated.workspace_files
    end

    test "handles files with atom keys in input" do
      sandbox = create_sandbox()

      {:ok, updated} =
        record_with_files(sandbox, [
          %{path: "script.py", size: 1024}
        ])

      assert [%{"path" => "script.py", "size" => 1024}] = updated.workspace_files
    end

    test "maps 'name' key to 'path' when 'path' is missing" do
      sandbox = create_sandbox()

      {:ok, updated} =
        record_with_files(sandbox, [
          %{"name" => "renamed.py", "size" => 200}
        ])

      assert [%{"path" => "renamed.py", "size" => 200}] = updated.workspace_files
    end

    test "defaults missing size to 0" do
      sandbox = create_sandbox()

      {:ok, updated} =
        record_with_files(sandbox, [
          %{"path" => "no_size.py"}
        ])

      assert [%{"path" => "no_size.py", "size" => 0}] = updated.workspace_files
    end

    test "rejects entries with nil path" do
      sandbox = create_sandbox()

      {:ok, updated} =
        record_with_files(sandbox, [
          %{"size" => 100},
          %{"path" => "keep.py", "size" => 50}
        ])

      assert [%{"path" => "keep.py", "size" => 50}] = updated.workspace_files
    end

    test "handles nil workspace_files argument (no change)" do
      sandbox = create_sandbox()

      {:ok, updated} =
        Sandbox.record_execution(
          sandbox,
          100,
          Decimal.new("0.001"),
          %{workspace_files: nil},
          authorize?: false
        )

      assert updated.workspace_files == []
    end

    test "handles empty list" do
      sandbox = create_sandbox()

      {:ok, updated} = record_with_files(sandbox, [])

      assert updated.workspace_files == []
    end

    test "replaces previous workspace_files (not append)" do
      sandbox = create_sandbox()

      {:ok, updated1} =
        record_with_files(sandbox, [
          %{"path" => "old.py", "size" => 100}
        ])

      assert [%{"path" => "old.py"}] = updated1.workspace_files

      {:ok, updated2} =
        record_with_files(updated1, [
          %{"path" => "new.py", "size" => 200}
        ])

      assert [%{"path" => "new.py", "size" => 200}] = updated2.workspace_files
      refute Enum.any?(updated2.workspace_files, &(&1["path"] == "old.py"))
    end
  end
end
