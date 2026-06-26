defmodule Magus.Files.FileUploadedViaAgentTest do
  use Magus.DataCase, async: true

  import Magus.Generators

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

  describe "uploaded_via_agent_id" do
    test "defaults to nil when not provided", %{user: user} do
      {:ok, file} =
        Magus.Files.create_file(
          %{
            name: "doc.pdf",
            type: :document,
            mime_type: "application/pdf",
            file_size: 1024,
            file_path: "tmp/doc.pdf"
          },
          actor: user
        )

      assert is_nil(file.uploaded_via_agent_id)
    end

    test "can be set on creation", %{user: user, agent: agent} do
      {:ok, file} =
        Magus.Files.create_file(
          %{
            name: "doc.pdf",
            type: :document,
            mime_type: "application/pdf",
            file_size: 1024,
            file_path: "tmp/doc.pdf",
            uploaded_via_agent_id: agent.id
          },
          actor: user
        )

      assert file.uploaded_via_agent_id == agent.id
    end
  end
end
