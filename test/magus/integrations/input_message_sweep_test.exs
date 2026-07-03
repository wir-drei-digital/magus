defmodule Magus.Integrations.InputMessageSweepTest do
  @moduledoc """
  Tests the stuck-InputMessage sweep: `InputMessage.stuck_processing` read
  action scopes to `:processing` messages whose `updated_at` is older than
  10 minutes, and `:fail_stuck_message` flips them to `:failed`.
  """

  use Magus.DataCase, async: true

  import Magus.Generators

  require Ash.Query

  alias Magus.Integrations
  alias Magus.Integrations.InputMessage

  defp create_input_message(user, attrs) do
    default_attrs = %{
      provider_key: :telegram,
      message_type: :text,
      payload: %{"text" => "hello"},
      user_id: user.id,
      # Skip SignalInputAgent's post-create async dispatch (spawned outside
      # the test's sandboxed connection via Task.Supervisor): these tests
      # only care about the stuck-sweep state machine, not real dispatch,
      # and letting it fire races the sandbox and can flip status
      # underneath the test.
      dispatched: true
    }

    {:ok, message} =
      Integrations.create_input_message(Map.merge(default_attrs, attrs), authorize?: false)

    message
  end

  defp backdate_updated_at(message, minutes_ago) do
    backdated = DateTime.add(DateTime.utc_now(), -minutes_ago, :minute)

    InputMessage
    |> Ecto.Query.where([m], m.id == ^message.id)
    |> Magus.Repo.update_all(set: [updated_at: backdated])

    {:ok, message} = Ash.get(InputMessage, message.id, authorize?: false)
    message
  end

  describe "stuck_processing read action" do
    test "includes a :processing message updated 15 minutes ago", %{} do
      user = generate(user())

      message =
        create_input_message(user, %{})
        |> then(fn m ->
          {:ok, m} =
            m |> Ash.Changeset.for_update(:mark_processing, %{}) |> Ash.update(authorize?: false)

          m
        end)
        |> backdate_updated_at(15)

      ids =
        InputMessage
        |> Ash.Query.for_read(:stuck_processing)
        |> Ash.read!(authorize?: false)
        |> Enum.map(& &1.id)

      assert message.id in ids
    end

    test "excludes a :processing message updated 2 minutes ago", %{} do
      user = generate(user())

      message =
        create_input_message(user, %{})
        |> then(fn m ->
          {:ok, m} =
            m |> Ash.Changeset.for_update(:mark_processing, %{}) |> Ash.update(authorize?: false)

          m
        end)
        |> backdate_updated_at(2)

      ids =
        InputMessage
        |> Ash.Query.for_read(:stuck_processing)
        |> Ash.read!(authorize?: false)
        |> Enum.map(& &1.id)

      refute message.id in ids
    end

    test "excludes a :pending message even if old", %{} do
      user = generate(user())

      message =
        create_input_message(user, %{})
        |> backdate_updated_at(20)

      assert message.status == :pending

      ids =
        InputMessage
        |> Ash.Query.for_read(:stuck_processing)
        |> Ash.read!(authorize?: false)
        |> Enum.map(& &1.id)

      refute message.id in ids
    end

    test "excludes an already-:failed message even if old", %{} do
      user = generate(user())

      message =
        create_input_message(user, %{})
        |> then(fn m ->
          {:ok, m} =
            m
            |> Ash.Changeset.for_update(:mark_failed, %{error_message: "boom"})
            |> Ash.update(authorize?: false)

          m
        end)
        |> backdate_updated_at(20)

      ids =
        InputMessage
        |> Ash.Query.for_read(:stuck_processing)
        |> Ash.read!(authorize?: false)
        |> Enum.map(& &1.id)

      refute message.id in ids
    end
  end

  describe "fail_stuck_message" do
    test "flips a stuck :processing message to :failed", %{} do
      user = generate(user())

      message =
        create_input_message(user, %{})
        |> then(fn m ->
          {:ok, m} =
            m |> Ash.Changeset.for_update(:mark_processing, %{}) |> Ash.update(authorize?: false)

          m
        end)
        |> backdate_updated_at(15)

      # NOTE on logging: `:fail_stuck_message` emits a `Logger.warning`
      # (id + integration id + age) via an after_action hook when it fails a
      # stuck message. This can't be asserted here because the test env sets
      # `config :logger, level: :none` (config/test.exs), so ExUnit's
      # `capture_log`/`with_log` capture nothing. The assertion below confirms
      # the change (which includes the logging hook) runs to completion.
      {:ok, updated} =
        message
        |> Ash.Changeset.for_update(:fail_stuck_message, %{})
        |> Ash.update(authorize?: false)

      assert updated.status == :failed
    end

    test "a fresh :processing message is not selected by the sweep's read gate", %{} do
      user = generate(user())

      message =
        create_input_message(user, %{})
        |> then(fn m ->
          {:ok, m} =
            m |> Ash.Changeset.for_update(:mark_processing, %{}) |> Ash.update(authorize?: false)

          m
        end)

      assert message.status == :processing

      # `fail_stuck_message` itself unconditionally fails whatever record
      # it's given; the "is it actually stuck" gate is the trigger's `where`
      # on `InputMessage.stuck_processing` (tested above). Confirm the fresh
      # message doesn't show up there, so the real (Oban-driven) sweep would
      # never reach it.
      ids =
        InputMessage
        |> Ash.Query.for_read(:stuck_processing)
        |> Ash.read!(authorize?: false)
        |> Enum.map(& &1.id)

      refute message.id in ids
    end
  end
end
