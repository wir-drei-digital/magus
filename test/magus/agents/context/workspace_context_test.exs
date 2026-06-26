defmodule Magus.Agents.Context.WorkspaceContextTest do
  use Magus.DataCase, async: true

  alias Magus.Agents.Context.WorkspaceContext
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

  defp create_sandbox_in_state(conversation_id, state, attrs \\ %{}) do
    {:ok, sandbox} = Sandbox.create_sandbox(conversation_id, authorize?: false)

    # Force-update state and extra attributes without triggering Sprites API
    sandbox
    |> Ash.Changeset.for_update(:record_execution, %{
      duration_ms: 0,
      cost_usd: Decimal.new("0"),
      workspace_files: attrs[:workspace_files]
    })
    |> Ash.Changeset.force_change_attribute(:state, state)
    |> Ash.Changeset.force_change_attribute(
      :installed_packages,
      attrs[:installed_packages] || []
    )
    |> Ash.Changeset.force_change_attribute(
      :last_executed_at,
      attrs[:last_executed_at]
    )
    |> Ash.update!(authorize?: false)
  end

  # ---------------------------------------------------------------------------
  # Tests for build/1 — nil cases
  # ---------------------------------------------------------------------------

  describe "build/1 returns nil" do
    test "for non-existent conversation (no sandbox)" do
      assert WorkspaceContext.build(Ecto.UUID.generate()) == nil
    end

    test "for uninitialized sandbox" do
      user = create_user()
      {:ok, conv} = Chat.create_conversation(%{title: "t"}, actor: user)
      {:ok, _sandbox} = Sandbox.create_sandbox(conv.id, authorize?: false)

      assert WorkspaceContext.build(conv.id) == nil
    end

    test "for terminated sandbox" do
      user = create_user()
      {:ok, conv} = Chat.create_conversation(%{title: "t"}, actor: user)
      _sandbox = create_sandbox_in_state(conv.id, :terminated)

      assert WorkspaceContext.build(conv.id) == nil
    end

    test "for non-binary input" do
      assert WorkspaceContext.build(nil) == nil
      assert WorkspaceContext.build(123) == nil
      assert WorkspaceContext.build(:atom) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Tests for build/1 — context string formatting
  # ---------------------------------------------------------------------------

  describe "build/1 with active sandbox" do
    setup do
      user = create_user()
      {:ok, conv} = Chat.create_conversation(%{title: "t"}, actor: user)
      %{user: user, conversation: conv}
    end

    test "returns context string for active sandbox", %{user: user, conversation: conv} do
      _sandbox =
        create_sandbox_in_state(conv.id, :active, %{
          workspace_files: [%{"path" => "main.py", "size" => 100}]
        })

      result = WorkspaceContext.build(conv.id, actor: user)

      assert is_binary(result)
      assert String.contains?(result, "Active Workspace")
    end

    test "returns context string for suspended sandbox", %{user: user, conversation: conv} do
      _sandbox =
        create_sandbox_in_state(conv.id, :suspended, %{
          workspace_files: [%{"path" => "main.py", "size" => 100}]
        })

      result = WorkspaceContext.build(conv.id, actor: user)

      assert is_binary(result)
      assert String.contains?(result, "Suspended")
    end

    test "includes Active status for active sandbox", %{user: user, conversation: conv} do
      _sandbox = create_sandbox_in_state(conv.id, :active)

      result = WorkspaceContext.build(conv.id, actor: user)
      assert String.contains?(result, "**Status:** Active")
    end

    test "includes Suspended status for suspended sandbox", %{user: user, conversation: conv} do
      _sandbox = create_sandbox_in_state(conv.id, :suspended)

      result = WorkspaceContext.build(conv.id, actor: user)
      assert String.contains?(result, "**Status:** Suspended")
    end

    test "includes installed packages when present", %{user: user, conversation: conv} do
      _sandbox =
        create_sandbox_in_state(conv.id, :active, %{
          installed_packages: ["numpy", "pandas"]
        })

      result = WorkspaceContext.build(conv.id, actor: user)
      assert String.contains?(result, "numpy, pandas")
      assert String.contains?(result, "Installed packages")
    end

    test "shows Empty workspace when no files", %{user: user, conversation: conv} do
      _sandbox = create_sandbox_in_state(conv.id, :active)

      result = WorkspaceContext.build(conv.id, actor: user)
      assert String.contains?(result, "**Workspace:** Empty")
    end

    test "lists files with paths and sizes", %{user: user, conversation: conv} do
      _sandbox =
        create_sandbox_in_state(conv.id, :active, %{
          workspace_files: [
            %{"path" => "main.py", "size" => 256},
            %{"path" => "utils.py", "size" => 1024}
          ]
        })

      result = WorkspaceContext.build(conv.id, actor: user)
      assert String.contains?(result, "main.py")
      assert String.contains?(result, "utils.py")
      assert String.contains?(result, "256 B")
      assert String.contains?(result, "1.0 KB")
    end

    test "truncates file list at 20 and shows remaining count", %{user: user, conversation: conv} do
      files =
        for i <- 1..25 do
          %{"path" => "file_#{String.pad_leading(to_string(i), 2, "0")}.py", "size" => 100}
        end

      _sandbox =
        create_sandbox_in_state(conv.id, :active, %{workspace_files: files})

      result = WorkspaceContext.build(conv.id, actor: user)
      assert String.contains?(result, "and 5 more files")
    end

    test "shows relative time for last_executed_at — just now", %{user: user, conversation: conv} do
      _sandbox =
        create_sandbox_in_state(conv.id, :active, %{
          last_executed_at: DateTime.utc_now()
        })

      result = WorkspaceContext.build(conv.id, actor: user)
      assert String.contains?(result, "just now")
    end

    test "shows relative time for last_executed_at — minutes ago", %{
      user: user,
      conversation: conv
    } do
      _sandbox =
        create_sandbox_in_state(conv.id, :active, %{
          last_executed_at: DateTime.add(DateTime.utc_now(), -300, :second)
        })

      result = WorkspaceContext.build(conv.id, actor: user)
      assert String.contains?(result, "5 minutes ago")
    end

    test "shows singular minute form", %{user: user, conversation: conv} do
      _sandbox =
        create_sandbox_in_state(conv.id, :active, %{
          last_executed_at: DateTime.add(DateTime.utc_now(), -60, :second)
        })

      result = WorkspaceContext.build(conv.id, actor: user)
      assert String.contains?(result, "1 minute ago")
    end

    test "shows relative time for last_executed_at — hours ago", %{user: user, conversation: conv} do
      _sandbox =
        create_sandbox_in_state(conv.id, :active, %{
          last_executed_at: DateTime.add(DateTime.utc_now(), -7200, :second)
        })

      result = WorkspaceContext.build(conv.id, actor: user)
      assert String.contains?(result, "2 hours ago")
    end

    test "shows singular hour form", %{user: user, conversation: conv} do
      _sandbox =
        create_sandbox_in_state(conv.id, :active, %{
          last_executed_at: DateTime.add(DateTime.utc_now(), -3600, :second)
        })

      result = WorkspaceContext.build(conv.id, actor: user)
      assert String.contains?(result, "1 hour ago")
    end

    test "shows relative time for last_executed_at — days ago", %{user: user, conversation: conv} do
      _sandbox =
        create_sandbox_in_state(conv.id, :active, %{
          last_executed_at: DateTime.add(DateTime.utc_now(), -172_800, :second)
        })

      result = WorkspaceContext.build(conv.id, actor: user)
      assert String.contains?(result, "2 days ago")
    end

    test "shows singular day form", %{user: user, conversation: conv} do
      _sandbox =
        create_sandbox_in_state(conv.id, :active, %{
          last_executed_at: DateTime.add(DateTime.utc_now(), -86400, :second)
        })

      result = WorkspaceContext.build(conv.id, actor: user)
      assert String.contains?(result, "1 day ago")
    end

    test "formats file sizes in KB range", %{user: user, conversation: conv} do
      _sandbox =
        create_sandbox_in_state(conv.id, :active, %{
          workspace_files: [%{"path" => "data.csv", "size" => 5120}]
        })

      result = WorkspaceContext.build(conv.id, actor: user)
      assert String.contains?(result, "5.0 KB")
    end

    test "formats file sizes in MB range", %{user: user, conversation: conv} do
      _sandbox =
        create_sandbox_in_state(conv.id, :active, %{
          workspace_files: [%{"path" => "model.pkl", "size" => 2_097_152}]
        })

      result = WorkspaceContext.build(conv.id, actor: user)
      assert String.contains?(result, "2.0 MB")
    end

    test "includes tool usage instructions", %{user: user, conversation: conv} do
      _sandbox = create_sandbox_in_state(conv.id, :active)

      result = WorkspaceContext.build(conv.id, actor: user)
      assert String.contains?(result, "sandbox_read_file")
      assert String.contains?(result, "sandbox_write_file")
    end
  end
end
