defmodule Magus.Agents.Context.AttachedDocumentsContextTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  alias Magus.Agents.Context.AttachedDocumentsContext

  setup do
    user = generate(user())
    free_plan = ensure_free_plan()

    {:ok, _subscription} =
      Magus.Usage.create_user_subscription(
        %{user_id: user.id, usage_plan_id: free_plan.id, status: :active},
        authorize?: false
      )

    agent = custom_agent(user)
    %{user: user, agent: agent}
  end

  test "returns empty string when no attachments", %{agent: agent} do
    agent = Ash.load!(agent, [attachments: [file: [:chunks]]], authorize?: false)
    assert AttachedDocumentsContext.build(agent) == ""
  end

  test "renders only :always-mode attachments in position order", %{user: user, agent: agent} do
    {:ok, f1} =
      Magus.Files.create_file(
        %{
          name: "Brand.pdf",
          type: :document,
          mime_type: "application/pdf",
          file_size: 1,
          file_path: "tmp/brand.pdf"
        },
        actor: user
      )

    {:ok, f2} =
      Magus.Files.create_file(
        %{
          name: "Voice.md",
          type: :text,
          mime_type: "text/markdown",
          file_size: 1,
          file_path: "tmp/voice.md"
        },
        actor: user
      )

    {:ok, f3} =
      Magus.Files.create_file(
        %{
          name: "Manual.pdf",
          type: :document,
          mime_type: "application/pdf",
          file_size: 1,
          file_path: "tmp/manual.pdf"
        },
        actor: user
      )

    seed_chunk!(f1, "Brand text content here", 0)
    seed_chunk!(f2, "Voice text content", 0)
    seed_chunk!(f3, "Manual content (search-mode, should NOT appear)", 0)

    {:ok, _} =
      Magus.Agents.create_attachment(
        %{custom_agent_id: agent.id, file_id: f2.id, mode: :always, position: 1},
        actor: user
      )

    {:ok, _} =
      Magus.Agents.create_attachment(
        %{custom_agent_id: agent.id, file_id: f1.id, mode: :always, position: 0},
        actor: user
      )

    {:ok, _} =
      Magus.Agents.create_attachment(
        %{custom_agent_id: agent.id, file_id: f3.id, mode: :search, position: 0},
        actor: user
      )

    rendered =
      AttachedDocumentsContext.build(
        Ash.load!(agent, [attachments: [file: [:chunks]]], authorize?: false)
      )

    assert rendered =~ "<attached_documents>"
    assert rendered =~ "<document name=\"Brand.pdf\""
    assert rendered =~ "Brand text content here"
    assert rendered =~ "Voice text content"
    refute rendered =~ "Manual content"
    # Order: f1 (position 0) before f2 (position 1)
    assert :binary.match(rendered, "Brand text content") <
             :binary.match(rendered, "Voice text content")
  end

  test "skips attachments whose underlying file is still processing", %{user: user, agent: agent} do
    {:ok, f} =
      Magus.Files.create_file(
        %{
          name: "Pending.pdf",
          type: :document,
          mime_type: "application/pdf",
          file_size: 1,
          file_path: "tmp/p.pdf"
        },
        actor: user
      )

    # No chunks seeded -> treat as pending
    {:ok, _} =
      Magus.Agents.create_attachment(
        %{custom_agent_id: agent.id, file_id: f.id, mode: :always, position: 0},
        actor: user
      )

    rendered =
      AttachedDocumentsContext.build(
        Ash.load!(agent, [attachments: [file: [:chunks]]], authorize?: false)
      )

    assert rendered == ""
  end

  defp seed_chunk!(file, content, position) do
    {:ok, chunk} =
      Magus.Files.Chunk
      |> Ash.Changeset.for_create(:create, %{
        file_id: file.id,
        content: content,
        position: position,
        token_count: max(div(byte_size(content), 4), 1)
      })
      |> Ash.create(authorize?: false)

    chunk
  end
end
