defmodule Magus.Agents.Plugins.AgentRunCompletionPluginArtifactsTest do
  use Magus.DataCase, async: false

  import Magus.Generators

  alias Magus.Agents.Plugins.AgentRunCompletionPlugin

  setup do
    user = generate(user())
    parent = generate(conversation(actor: user))
    child = generate(conversation(actor: user))
    user = Ash.load!(user, [], authorize?: false)

    # Create a file in the child conversation
    Magus.Files.create_file_from_content!(
      %{
        name: "report.pdf",
        type: :document,
        mime_type: "application/pdf",
        user_id: user.id,
        conversation_id: child.id,
        content: "pdf content"
      },
      actor: %Magus.Agents.Support.AiAgent{}
    )

    %{user: user, parent: parent, child: child}
  end

  describe "build_artifacts_step/1" do
    test "creates step with file listing", %{child: child} do
      step = AgentRunCompletionPlugin.build_artifacts_step(child.id)

      assert step.label == "Artifacts"
      assert step.status == :complete
      assert step.data.type == :artifacts
      assert length(step.data.files) == 1
      assert hd(step.data.files).name == "report.pdf"
      assert String.contains?(step.content, "report.pdf")
    end

    test "returns nil when no files exist", %{parent: parent} do
      step = AgentRunCompletionPlugin.build_artifacts_step(parent.id)
      assert is_nil(step)
    end
  end
end
