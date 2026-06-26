defmodule Magus.Agents.Context.BuilderCompanionTest do
  use Magus.ResourceCase, async: false

  alias Magus.Agents.Context.Builder
  alias Magus.Chat

  defp load_conversation(id, user) do
    Magus.Chat.get_conversation!(id,
      load: [
        :workspace,
        active_system_prompt: [:model],
        members: [:user],
        custom_agent: [:model, :image_model, :video_model],
        user: [:selected_model, :selected_image_model, :selected_video_model]
      ],
      actor: user
    )
  end

  test "system prompt includes companion preamble for file companion conversations" do
    user = generate(user())
    ws = generate(workspace(actor: user))
    ensure_workspace_plan(user)

    {:ok, file} =
      Magus.Files.create_file(
        %{
          name: "x.pdf",
          type: :document,
          mime_type: "application/pdf",
          file_size: 1,
          file_path: "#{user.id}/#{Ash.UUIDv7.generate()}.pdf",
          workspace_id: ws.id
        },
        actor: user
      )

    {:ok, conv} = Chat.find_or_create_companion_conversation(:file, file.id, actor: user)
    conv = load_conversation(conv.id, user)

    {system_prompt, _messages} =
      Builder.build_llm_context(
        conv,
        Ash.UUIDv7.generate(),
        "hello",
        [],
        :chat,
        "openrouter:test/model",
        %{}
      )

    assert system_prompt =~ "Active companion context"
    assert system_prompt =~ "x.pdf"
  end
end
