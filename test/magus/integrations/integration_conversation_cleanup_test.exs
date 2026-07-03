defmodule Magus.Integrations.IntegrationConversationCleanupTest do
  @moduledoc """
  Regression pins for `IntegrationConversation` orphan cleanup (Phase 4, Task 2).

  Both orphan paths investigated for this task are already covered by
  DB-level `ON DELETE CASCADE` foreign keys (declared in the resource's
  `postgres.references` block and confirmed against the actual migrations:
  `20260321100000_add_cascade_deletes_for_conversations.exs` for
  `conversation_id`, `20260328230000_cascade_delete_user_integration_dependents.exs`
  for `user_integration_id`). Deactivating a `UserIntegration` (`:deactivate`
  action) only flips `status`, it never destroys the row, so it is
  deliberately NOT a cleanup path here: reactivation must resume the same
  mapped conversations.

  These tests are regression PINS, not TDD: they pass immediately against
  the existing cascade behavior. They exist to catch any future migration
  or resource change that silently drops the cascade.
  """

  use Magus.DataCase, async: true

  import Magus.Generators

  require Ash.Query

  alias Magus.Chat
  alias Magus.Integrations
  alias Magus.Integrations.IntegrationConversation

  defp create_integration(user, agent) do
    {:ok, integration} =
      Integrations.create_user_integration(
        :telegram,
        %{
          custom_agent_id: agent.id,
          user_id: user.id,
          conversation_mode: :multi,
          config: %{}
        },
        actor: user
      )

    integration
  end

  defp mapping_ids(user_integration_id) do
    IntegrationConversation
    |> Ash.Query.filter(user_integration_id == ^user_integration_id)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.id)
  end

  describe "regression pin: destroying a UserIntegration cascades its IntegrationConversation mappings" do
    test "mapping rows are gone after the UserIntegration is destroyed" do
      user = generate(user())
      agent = custom_agent(user, %{name: "Cleanup Owner"})
      integration = create_integration(user, agent)
      conversation = generate(conversation(actor: user))

      {:ok, mapping} =
        Integrations.create_integration_conversation(
          %{
            external_identifier: "chat-123",
            user_integration_id: integration.id,
            conversation_id: conversation.id
          },
          actor: user
        )

      assert mapping.id in mapping_ids(integration.id)

      :ok = Ash.destroy(integration, actor: user)

      assert mapping_ids(integration.id) == []
      assert {:error, _} = Ash.get(IntegrationConversation, mapping.id, authorize?: false)
    end
  end

  describe "regression pin: destroying a Conversation cascades its IntegrationConversation mappings" do
    test "mapping rows are gone after the Conversation is destroyed" do
      user = generate(user())
      agent = custom_agent(user, %{name: "Cleanup Owner 2"})
      integration = create_integration(user, agent)
      conversation = generate(conversation(actor: user))

      {:ok, mapping} =
        Integrations.create_integration_conversation(
          %{
            external_identifier: "chat-456",
            user_integration_id: integration.id,
            conversation_id: conversation.id
          },
          actor: user
        )

      assert mapping.id in mapping_ids(integration.id)

      :ok = Chat.delete_full_conversation(conversation, actor: user)

      assert mapping_ids(integration.id) == []
      assert {:error, _} = Ash.get(IntegrationConversation, mapping.id, authorize?: false)
    end
  end

  describe "not a cleanup path: deactivating a UserIntegration keeps its mappings" do
    test "mapping rows survive :deactivate so reactivation can resume the same conversations" do
      user = generate(user())
      agent = custom_agent(user, %{name: "Cleanup Owner 3"})
      integration = create_integration(user, agent)
      conversation = generate(conversation(actor: user))

      {:ok, mapping} =
        Integrations.create_integration_conversation(
          %{
            external_identifier: "chat-789",
            user_integration_id: integration.id,
            conversation_id: conversation.id
          },
          actor: user
        )

      {:ok, deactivated} =
        integration
        |> Ash.Changeset.for_update(:deactivate, %{})
        |> Ash.update(actor: user)

      assert deactivated.status == :disabled
      assert mapping.id in mapping_ids(integration.id)
    end
  end
end
