defmodule Magus.Agents.Context.SystemPromptsAttachedDocsTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  alias Magus.Agents.Context.SystemPrompts

  test "always-include attachments end up in the composed system prompt" do
    user = generate(user())
    free_plan = ensure_free_plan()

    {:ok, _subscription} =
      Magus.Usage.create_user_subscription(
        %{user_id: user.id, usage_plan_id: free_plan.id, status: :active},
        authorize?: false
      )

    agent = custom_agent(user, %{instructions: "You are the brand voice agent."})

    {:ok, file} =
      Magus.Files.create_file(
        %{
          name: "Brand.pdf",
          type: :document,
          mime_type: "application/pdf",
          file_size: 1,
          file_path: "tmp/b.pdf"
        },
        actor: user
      )

    {:ok, _} =
      Magus.Files.Chunk
      |> Ash.Changeset.for_create(:create, %{
        file_id: file.id,
        content: "Always speak in active voice and avoid em dashes.",
        position: 0,
        token_count: 12
      })
      |> Ash.create(authorize?: false)

    {:ok, _} =
      Magus.Agents.create_attachment(
        %{custom_agent_id: agent.id, file_id: file.id, mode: :always, position: 0},
        actor: user
      )

    agent = Ash.load!(agent, [attachments: [file: [:chunks]]], authorize?: false)

    attached_docs = Magus.Agents.Context.AttachedDocumentsContext.build(agent)

    prompt =
      SystemPrompts.build(
        mode: :chat,
        custom_agent: agent,
        user: user,
        attached_documents_context: attached_docs
      )

    assert prompt =~ "You are the brand voice agent."
    assert prompt =~ "<attached_documents>"
    assert prompt =~ "Always speak in active voice"
  end
end
