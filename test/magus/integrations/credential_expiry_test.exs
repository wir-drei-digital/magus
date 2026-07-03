defmodule Magus.Integrations.CredentialExpiryTest do
  @moduledoc """
  Tests the credential expiry warning sweep: `Credential.expiring_soon` read
  action scopes to credentials expiring within 7 days that haven't already
  been warned, `:process_expiry_warning` sets `expiry_warned_at` + notifies
  the owner for soon-to-expire credentials, and marks the linked
  `UserIntegration` `:error` + notifies for already-expired credentials.
  """

  use Magus.DataCase, async: true

  import Magus.Generators

  require Ash.Query

  alias Magus.Integrations
  alias Magus.Integrations.Credential

  defp create_integration(user) do
    agent = custom_agent(user, %{name: "Credential Owner"})

    {:ok, integration} =
      Integrations.create_user_integration(
        :google_calendar,
        %{
          custom_agent_id: agent.id,
          user_id: user.id,
          config: %{}
        },
        actor: user
      )

    integration
  end

  defp create_credential(integration, attrs) do
    default_attrs = %{
      credential_type: :oauth2,
      encrypted_data: %{"access_token" => "tok"},
      user_integration_id: integration.id
    }

    {:ok, credential} =
      Integrations.create_credential(Map.merge(default_attrs, attrs), authorize?: false)

    credential
  end

  defp backdate_expiry_warned_at(credential, minutes_ago) do
    backdated = DateTime.add(DateTime.utc_now(), -minutes_ago, :minute)

    Credential
    |> Ecto.Query.where([c], c.id == ^credential.id)
    |> Magus.Repo.update_all(set: [expiry_warned_at: backdated])

    {:ok, credential} = Ash.get(Credential, credential.id, authorize?: false)
    credential
  end

  describe "expiring_soon read action" do
    test "includes a credential expiring in 3 days", %{} do
      user = generate(user())
      integration = create_integration(user)

      credential =
        create_credential(integration, %{
          expires_at: DateTime.add(DateTime.utc_now(), 3, :day)
        })

      ids =
        Credential
        |> Ash.Query.for_read(:expiring_soon)
        |> Ash.read!(authorize?: false)
        |> Enum.map(& &1.id)

      assert credential.id in ids
    end

    test "excludes a credential expiring in 8 days", %{} do
      user = generate(user())
      integration = create_integration(user)

      credential =
        create_credential(integration, %{
          expires_at: DateTime.add(DateTime.utc_now(), 8, :day)
        })

      ids =
        Credential
        |> Ash.Query.for_read(:expiring_soon)
        |> Ash.read!(authorize?: false)
        |> Enum.map(& &1.id)

      refute credential.id in ids
    end

    test "excludes a credential with nil expires_at", %{} do
      user = generate(user())
      integration = create_integration(user)

      credential = create_credential(integration, %{})

      assert credential.expires_at == nil

      ids =
        Credential
        |> Ash.Query.for_read(:expiring_soon)
        |> Ash.read!(authorize?: false)
        |> Enum.map(& &1.id)

      refute credential.id in ids
    end

    test "excludes an already-warned credential still in the window", %{} do
      user = generate(user())
      integration = create_integration(user)

      credential =
        create_credential(integration, %{
          expires_at: DateTime.add(DateTime.utc_now(), 3, :day)
        })
        |> backdate_expiry_warned_at(5)

      ids =
        Credential
        |> Ash.Query.for_read(:expiring_soon)
        |> Ash.read!(authorize?: false)
        |> Enum.map(& &1.id)

      refute credential.id in ids
    end

    test "includes an already-expired credential (single sweep gate; the change module branches on expired vs. soon)",
         %{} do
      user = generate(user())
      integration = create_integration(user)

      credential =
        create_credential(integration, %{
          expires_at: DateTime.add(DateTime.utc_now(), -1, :day)
        })

      ids =
        Credential
        |> Ash.Query.for_read(:expiring_soon)
        |> Ash.read!(authorize?: false)
        |> Enum.map(& &1.id)

      assert credential.id in ids
    end
  end

  describe "process_expiry_warning: soon-to-expire credential" do
    test "sets expiry_warned_at and notifies the owner", %{} do
      user = generate(user())
      integration = create_integration(user)

      credential =
        create_credential(integration, %{
          expires_at: DateTime.add(DateTime.utc_now(), 3, :day)
        })

      {:ok, updated} =
        credential
        |> Ash.Changeset.for_update(:process_expiry_warning, %{})
        |> Ash.update(authorize?: false)

      assert %DateTime{} = updated.expiry_warned_at

      {:ok, reloaded_integration} =
        Integrations.get_user_integration(integration.id, authorize?: false)

      # Not expired yet: integration status untouched.
      refute reloaded_integration.status == :error

      {:ok, notifications} = Magus.Notifications.list_unread_notifications(actor: user)
      assert length(notifications) == 1
      assert hd(notifications).notification_type == :system
    end

    test "does not notify twice for the same credential", %{} do
      user = generate(user())
      integration = create_integration(user)

      credential =
        create_credential(integration, %{
          expires_at: DateTime.add(DateTime.utc_now(), 3, :day)
        })

      {:ok, updated} =
        credential
        |> Ash.Changeset.for_update(:process_expiry_warning, %{})
        |> Ash.update(authorize?: false)

      {:ok, _updated_again} =
        updated
        |> Ash.Changeset.for_update(:process_expiry_warning, %{})
        |> Ash.update(authorize?: false)

      {:ok, notifications} = Magus.Notifications.list_unread_notifications(actor: user)
      assert length(notifications) == 1
    end
  end

  describe "process_expiry_warning: already-expired credential" do
    test "marks the linked integration :error and notifies the owner", %{} do
      user = generate(user())
      integration = create_integration(user)

      credential =
        create_credential(integration, %{
          expires_at: DateTime.add(DateTime.utc_now(), -1, :day)
        })

      {:ok, _updated} =
        credential
        |> Ash.Changeset.for_update(:process_expiry_warning, %{})
        |> Ash.update(authorize?: false)

      {:ok, reloaded_integration} =
        Integrations.get_user_integration(integration.id, authorize?: false)

      assert reloaded_integration.status == :error

      {:ok, notifications} = Magus.Notifications.list_unread_notifications(actor: user)
      assert length(notifications) == 1
      assert hd(notifications).notification_type == :system
    end

    test "does not notify again once the integration is already errored", %{} do
      user = generate(user())
      integration = create_integration(user)

      credential =
        create_credential(integration, %{
          expires_at: DateTime.add(DateTime.utc_now(), -1, :day)
        })

      {:ok, updated} =
        credential
        |> Ash.Changeset.for_update(:process_expiry_warning, %{})
        |> Ash.update(authorize?: false)

      {:ok, _updated_again} =
        updated
        |> Ash.Changeset.for_update(:process_expiry_warning, %{})
        |> Ash.update(authorize?: false)

      {:ok, notifications} = Magus.Notifications.list_unread_notifications(actor: user)
      assert length(notifications) == 1
    end
  end

  describe "expiry_warned_at reset on credential refresh" do
    test "refresh_token clears expiry_warned_at so a new expiry can warn again", %{} do
      user = generate(user())
      integration = create_integration(user)

      credential =
        create_credential(integration, %{
          expires_at: DateTime.add(DateTime.utc_now(), 3, :day)
        })

      {:ok, warned} =
        credential
        |> Ash.Changeset.for_update(:process_expiry_warning, %{})
        |> Ash.update(authorize?: false)

      assert %DateTime{} = warned.expiry_warned_at

      {:ok, refreshed} =
        Integrations.refresh_credential(
          warned,
          %{
            encrypted_data: %{"access_token" => "new-tok"},
            expires_at: DateTime.add(DateTime.utc_now(), 30, :day)
          },
          authorize?: false
        )

      assert refreshed.expiry_warned_at == nil
    end
  end
end
