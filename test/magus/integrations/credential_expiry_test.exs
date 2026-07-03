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

    test "warned-in-window then expired: expired branch runs despite expiry_warned_at being set",
         %{} do
      user = generate(user())
      integration = create_integration(user)

      # Credential warned while still in-window (expiry_warned_at stamped),
      # then time passes and expires_at is now in the past. The sweep must still
      # select it (`is_expiring_or_expired` includes anything already expired)
      # and run the expired branch — erroring the integration + notifying —
      # even though expiry_warned_at is set.
      credential =
        create_credential(integration, %{
          expires_at: DateTime.add(DateTime.utc_now(), -1, :hour)
        })
        |> backdate_expiry_warned_at(60)

      assert %DateTime{} = credential.expiry_warned_at

      ids =
        Credential
        |> Ash.Query.for_read(:expiring_soon)
        |> Ash.read!(authorize?: false)
        |> Enum.map(& &1.id)

      assert credential.id in ids

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

  describe "reconnect via SetupIntegration replaces credentials" do
    setup %{} do
      user = generate(user())
      agent = custom_agent(user, %{name: "Reconnect Owner"})

      %{user: user, agent: agent}
    end

    defp all_credentials(integration_id) do
      require Ash.Query

      Credential
      |> Ash.Query.filter(user_integration_id == ^integration_id)
      |> Ash.read!(authorize?: false)
    end

    defp setup_integration(user, agent, credentials) do
      {:ok, integration} =
        Reactor.run(Magus.Integrations.Reactors.SetupIntegration, %{
          user_id: user.id,
          custom_agent_id: agent.id,
          provider_key: :google_calendar,
          credentials: credentials,
          config: %{}
        })

      integration
    end

    test "reconnecting destroys the old credential and does not re-error the healthy integration",
         %{user: user, agent: agent} do
      # Initial connect.
      integration = setup_integration(user, agent, %{"access_token" => "old-token"})

      [old_credential] = all_credentials(integration.id)

      # Simulate the credential having expired and the integration having been
      # errored by a prior sweep.
      Credential
      |> Ecto.Query.where([c], c.id == ^old_credential.id)
      |> Magus.Repo.update_all(set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :day)])

      {:ok, _} = Integrations.mark_integration_errored(integration, authorize?: false)

      # Reconnect via the same SetupIntegration path (fresh, non-expired token).
      reconnected = setup_integration(user, agent, %{"access_token" => "new-token"})

      # Same integration row is reused (upsert), not a duplicate.
      assert reconnected.id == integration.id

      # Old credential row is gone; exactly one (new) credential remains.
      credentials = all_credentials(integration.id)
      assert length(credentials) == 1
      new_credential = hd(credentials)
      refute new_credential.id == old_credential.id

      # get_credential_for_integration (a `get? true` read) returns the new row
      # without raising on duplicates.
      {:ok, fetched} =
        Integrations.get_credential_for_integration(integration.id, authorize?: false)

      assert fetched.id == new_credential.id
      assert fetched.encrypted_data == %{"access_token" => "new-token"}

      # A subsequent expiry sweep over the (now healthy) new credential must not
      # re-error the reconnected integration: the new credential isn't expired,
      # and the stale expired row is gone.
      for credential <- all_credentials(integration.id) do
        credential
        |> Ash.Changeset.for_update(:process_expiry_warning, %{})
        |> Ash.update!(authorize?: false)
      end

      {:ok, reloaded} = Integrations.get_user_integration(integration.id, authorize?: false)
      refute reloaded.status == :error
    end

    test "stale-row guard: a leaked older expired credential is skipped, integration not errored",
         %{user: user, agent: agent} do
      # Belt-and-braces: even if some other path leaked a duplicate, the sweep
      # skips a credential that has a newer sibling for the same integration.
      integration = setup_integration(user, agent, %{"access_token" => "current"})
      [current] = all_credentials(integration.id)

      # Manually inject an OLDER, already-expired credential row (as if leaked by
      # a pre-fix reconnect).
      {:ok, stale} =
        Integrations.create_credential(
          %{
            user_integration_id: integration.id,
            credential_type: :oauth2,
            encrypted_data: %{"access_token" => "stale"},
            expires_at: DateTime.add(DateTime.utc_now(), -1, :day)
          },
          authorize?: false
        )

      # Backdate the stale row's inserted_at so `current` is unambiguously newer.
      Credential
      |> Ecto.Query.where([c], c.id == ^stale.id)
      |> Magus.Repo.update_all(set: [inserted_at: DateTime.add(current.inserted_at, -1, :hour)])

      {:ok, stale} = Ash.get(Credential, stale.id, authorize?: false)

      stale
      |> Ash.Changeset.for_update(:process_expiry_warning, %{})
      |> Ash.update!(authorize?: false)

      {:ok, reloaded} = Integrations.get_user_integration(integration.id, authorize?: false)
      refute reloaded.status == :error
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
