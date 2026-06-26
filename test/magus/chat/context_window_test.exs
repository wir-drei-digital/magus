defmodule Magus.Chat.ContextWindowTest do
  use Magus.ResourceCase, async: true
  require Ash.Query
  import Mox

  alias Magus.Agents.Support.AiAgent
  alias Magus.Test.MockResponses
  alias Magus.Test.Mocks.LLMMock

  setup :verify_on_exit!

  setup do
    user = generate(user())
    conv = generate(conversation(actor: user))
    %{user: user, conv: conv}
  end

  test "get_or_create returns one row per conversation", %{conv: conv} do
    {:ok, cw1} = Magus.Chat.get_or_create_context_window(conv.id, actor: %AiAgent{})
    {:ok, cw2} = Magus.Chat.get_or_create_context_window(conv.id, actor: %AiAgent{})
    assert cw1.id == cw2.id
    assert cw1.compaction_status == :idle
  end

  test "upsert_snapshot stores the breakdown + token fields", %{conv: conv} do
    {:ok, _} = Magus.Chat.get_or_create_context_window(conv.id, actor: %AiAgent{})

    {:ok, updated} =
      Magus.Chat.upsert_context_snapshot(%{
        conversation_id: conv.id,
        last_breakdown: %{"categories" => []},
        last_total_tokens: 1234,
        last_model_key: "openrouter:test",
        last_max_context: 200_000
      })

    assert updated.last_total_tokens == 1234
  end

  test "summary_message_count defaults to 0 and is never nil", %{conv: conv} do
    {:ok, cw} = Magus.Chat.get_or_create_context_window(conv.id, actor: %AiAgent{})
    assert cw.summary_message_count == 0
    refute is_nil(cw.summary_message_count)
  end

  test "config/1 reads defaults" do
    assert Magus.Chat.ContextWindow.config(:default_strategy) == :rolling
    assert is_integer(Magus.Chat.ContextWindow.config(:compaction_tail))
  end

  test "clear sets the pointer to the given message and nulls the summary", %{
    user: user,
    conv: conv
  } do
    {:ok, cw} = Magus.Chat.get_or_create_context_window(conv.id, actor: %AiAgent{})

    # Seed a pre-existing summary to prove clear nulls it. force_change_attribute
    # bypasses the action's accept list, so any update action carries the change.
    seeded =
      cw
      |> Ash.Changeset.for_update(:patch_usage, %{})
      |> Ash.Changeset.force_change_attribute(:summary, "old summary")
      |> Ash.Changeset.force_change_attribute(:summary_message_count, 7)
      |> Ash.update!()

    assert seeded.summary == "old summary"
    assert seeded.summary_message_count == 7

    # Real message to satisfy the window_start_message_id FK.
    msg = generate(message(actor: user, conversation_id: conv.id, text: "anchor"))
    at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, cleared} =
      Magus.Chat.clear_context_window(
        seeded,
        %{
          window_start_message_id: msg.id,
          window_start_at: at
        },
        actor: user
      )

    assert cleared.window_start_message_id == msg.id
    assert cleared.window_start_at == at
    assert cleared.summary == nil
    assert cleared.summary_message_count == 0
  end

  test "resolve_strategy prefers conversation override, then user default, then config" do
    cfg = Magus.Chat.ContextWindow.config(:default_strategy)

    assert Magus.Chat.ContextWindow.resolve_strategy(%{
             strategy: :compact,
             user_default: :rolling
           }) == :compact

    assert Magus.Chat.ContextWindow.resolve_strategy(%{strategy: nil, user_default: :compact}) ==
             :compact

    assert Magus.Chat.ContextWindow.resolve_strategy(%{strategy: nil, user_default: nil}) == cfg
  end

  # ============================================================================
  # Compaction state machine
  # ============================================================================

  describe "compaction state machine" do
    test "request_compaction sets :pending (owner actor)", %{user: user, conv: conv} do
      {:ok, cw} = Magus.Chat.get_or_create_context_window(conv.id, actor: %AiAgent{})

      {:ok, requested} =
        Magus.Chat.request_context_compaction(cw, %{}, actor: user)

      assert requested.compaction_status == :pending
    end

    test "mark_compacting sets :running (Ai agent actor)", %{conv: conv} do
      {:ok, cw} = Magus.Chat.get_or_create_context_window(conv.id, actor: %AiAgent{})

      {:ok, running} =
        Magus.Chat.mark_context_compacting(cw, %{}, actor: %AiAgent{})

      assert running.compaction_status == :running
    end

    test "compact stores the summary, advances the pointer, and returns to :idle", %{
      user: user,
      conv: conv
    } do
      {:ok, cw} = Magus.Chat.get_or_create_context_window(conv.id, actor: %AiAgent{})

      # Real message to satisfy the window_start_message_id FK.
      msg = generate(message(actor: user, conversation_id: conv.id, text: "anchor"))
      at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      {:ok, compacted} =
        Magus.Chat.compact_context_window(
          cw,
          %{
            summary: "rolled-up summary",
            summary_message_count: 3,
            window_start_message_id: msg.id,
            window_start_at: at
          },
          # The Oban trigger runs as the system AI agent.
          actor: %AiAgent{}
        )

      assert compacted.summary == "rolled-up summary"
      assert compacted.summary_message_count == 3
      assert compacted.window_start_message_id == msg.id
      assert compacted.window_start_at == at
      assert compacted.compaction_status == :idle
    end

    test "mark_failed sets :failed (Ai agent actor)", %{conv: conv} do
      {:ok, cw} = Magus.Chat.get_or_create_context_window(conv.id, actor: %AiAgent{})

      {:ok, failed} =
        Magus.Chat.mark_context_compaction_failed(cw, %{}, actor: %AiAgent{})

      assert failed.compaction_status == :failed
    end

    test "a non-owner is forbidden from request_compaction", %{conv: conv} do
      other = generate(user())
      {:ok, cw} = Magus.Chat.get_or_create_context_window(conv.id, actor: %AiAgent{})

      assert {:error, %Ash.Error.Forbidden{}} =
               Magus.Chat.request_context_compaction(cw, %{}, actor: other)
    end

    test "the AI agent can run compact, mark_compacting, and mark_failed", %{
      user: user,
      conv: conv
    } do
      {:ok, cw} = Magus.Chat.get_or_create_context_window(conv.id, actor: %AiAgent{})
      msg = generate(message(actor: user, conversation_id: conv.id, text: "anchor"))
      at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      {:ok, running} = Magus.Chat.mark_context_compacting(cw, %{}, actor: %AiAgent{})
      assert running.compaction_status == :running

      {:ok, compacted} =
        Magus.Chat.compact_context_window(
          running,
          %{
            summary: "s",
            summary_message_count: 1,
            window_start_message_id: msg.id,
            window_start_at: at
          },
          actor: %AiAgent{}
        )

      assert compacted.compaction_status == :idle

      {:ok, failed} = Magus.Chat.mark_context_compaction_failed(compacted, %{}, actor: %AiAgent{})
      assert failed.compaction_status == :failed
    end
  end

  # ============================================================================
  # Authorization policies
  # ============================================================================

  describe "authorization" do
    test "get_or_create is owner-gated: owner and AI agent succeed, non-owner forbidden", %{
      user: user,
      conv: conv
    } do
      # Owner can create/fetch the row.
      {:ok, owned} = Magus.Chat.get_or_create_context_window(conv.id, actor: user)
      assert owned.conversation_id == conv.id

      # System AI agent can too (bypass) — returns the same row.
      {:ok, agent_row} = Magus.Chat.get_or_create_context_window(conv.id, actor: %AiAgent{})
      assert agent_row.id == owned.id

      # A non-owner is forbidden: get_or_create is an upsert that would otherwise
      # leak the existing row for an arbitrary conversation_id.
      other = generate(user())

      assert {:error, %Ash.Error.Forbidden{}} =
               Magus.Chat.get_or_create_context_window(conv.id, actor: other)
    end

    test "the AI agent actor can read and upsert", %{conv: conv} do
      {:ok, _} =
        Magus.Chat.upsert_context_snapshot(
          %{conversation_id: conv.id, last_total_tokens: 7},
          actor: %AiAgent{}
        )

      {:ok, cw} = Magus.Chat.get_context_window(conv.id, actor: %AiAgent{})
      assert cw.last_total_tokens == 7
    end

    test "the conversation owner can read, set_strategy, and clear", %{user: user, conv: conv} do
      {:ok, cw} = Magus.Chat.get_or_create_context_window(conv.id, actor: %AiAgent{})

      {:ok, read} = Magus.Chat.get_context_window(conv.id, actor: user)
      assert read.id == cw.id

      {:ok, strategized} =
        Magus.Chat.set_context_strategy(cw, %{strategy: :compact}, actor: user)

      assert strategized.strategy == :compact

      {:ok, cleared} = Magus.Chat.clear_context_window(strategized, %{}, actor: user)
      assert cleared.summary == nil
    end

    test "a non-owner is forbidden from set_strategy", %{conv: conv} do
      other = generate(user())
      {:ok, cw} = Magus.Chat.get_or_create_context_window(conv.id, actor: %AiAgent{})

      assert {:error, %Ash.Error.Forbidden{}} =
               Magus.Chat.set_context_strategy(cw, %{strategy: :compact}, actor: other)
    end

    test "a non-owner is forbidden from clear", %{conv: conv} do
      other = generate(user())
      {:ok, cw} = Magus.Chat.get_or_create_context_window(conv.id, actor: %AiAgent{})

      assert {:error, %Ash.Error.Forbidden{}} =
               Magus.Chat.clear_context_window(cw, %{}, actor: other)
    end

    test "a non-owner cannot read the window (filtered out)", %{conv: conv} do
      other = generate(user())
      {:ok, _} = Magus.Chat.get_or_create_context_window(conv.id, actor: %AiAgent{})

      # Read policies act as filters: the row is filtered out for a non-owner.
      # The get? read then surfaces NotFound (wrapped in Invalid) rather than
      # leaking a forbidden signal, mirroring the conversation read convention.
      assert {:error, %Ash.Error.Invalid{}} =
               Magus.Chat.get_context_window(conv.id, actor: other)
    end
  end

  # ============================================================================
  # Conversation-keyed shared operations (LiveView donut + SPA RPC surface)
  # ============================================================================

  describe "conversation-keyed operations" do
    setup %{conv: conv} do
      MagusWeb.Endpoint.subscribe("agents:#{conv.id}")
      :ok
    end

    test "owner clears by conversation_id: pointer advances past the latest message + broadcast",
         %{user: user, conv: conv} do
      msg = generate(message(actor: user, conversation_id: conv.id, text: "latest"))

      {:ok, cleared} = Magus.Chat.clear_context_for_conversation(conv.id, actor: user)

      assert cleared.conversation_id == conv.id
      # Floor anchors on the latest message, just past its timestamp.
      assert cleared.window_start_message_id == msg.id
      assert DateTime.compare(cleared.window_start_at, msg.inserted_at) == :gt
      assert cleared.summary == nil
      assert cleared.summary_message_count == 0

      assert_receive %Phoenix.Socket.Broadcast{
        event: "agent_signal",
        payload: %{type: "context.updated"}
      }
    end

    test "clear with no messages sets a now-ish floor + nil pointer", %{user: user, conv: conv} do
      before = DateTime.utc_now()
      {:ok, cleared} = Magus.Chat.clear_context_for_conversation(conv.id, actor: user)
      later = DateTime.utc_now()

      assert cleared.window_start_message_id == nil
      assert DateTime.compare(cleared.window_start_at, before) in [:gt, :eq]
      assert DateTime.compare(cleared.window_start_at, later) in [:lt, :eq]
    end

    test "owner compacts by conversation_id: status -> :pending + broadcast", %{
      user: user,
      conv: conv
    } do
      {:ok, requested} = Magus.Chat.compact_context_for_conversation(conv.id, actor: user)

      assert requested.conversation_id == conv.id
      assert requested.compaction_status == :pending

      assert_receive %Phoenix.Socket.Broadcast{
        event: "agent_signal",
        payload: %{type: "context.updated"}
      }
    end

    test "owner sets strategy by conversation_id: override stored + broadcast", %{
      user: user,
      conv: conv
    } do
      {:ok, updated} =
        Magus.Chat.set_context_strategy_for_conversation(conv.id, :compact, actor: user)

      assert updated.conversation_id == conv.id
      assert updated.strategy == :compact

      assert_receive %Phoenix.Socket.Broadcast{
        event: "agent_signal",
        payload: %{type: "context.updated"}
      }
    end

    test "operations get-or-create the row on first call (no prior window)", %{
      user: user,
      conv: conv
    } do
      # No get_or_create beforehand: the generic action must create the row.
      {:ok, updated} =
        Magus.Chat.set_context_strategy_for_conversation(conv.id, :rolling, actor: user)

      assert updated.strategy == :rolling
      {:ok, read} = Magus.Chat.get_context_window(conv.id, actor: user)
      assert read.id == updated.id
    end

    test "a non-owner is forbidden from clear/compact/set_strategy by conversation_id", %{
      conv: conv
    } do
      other = generate(user())

      assert {:error, %Ash.Error.Forbidden{}} =
               Magus.Chat.clear_context_for_conversation(conv.id, actor: other)

      assert {:error, %Ash.Error.Forbidden{}} =
               Magus.Chat.compact_context_for_conversation(conv.id, actor: other)

      assert {:error, %Ash.Error.Forbidden{}} =
               Magus.Chat.set_context_strategy_for_conversation(conv.id, :compact, actor: other)

      # No broadcast should leak for a forbidden caller.
      refute_receive %Phoenix.Socket.Broadcast{event: "agent_signal"}
    end
  end

  # ============================================================================
  # run_compaction broadcasts on every settle (no-op / success / failed)
  # ============================================================================

  describe "run_compaction broadcasts context.updated on every settle" do
    # `user` stays in context from the top-level setup; the success-path test
    # destructures it. This inner setup only needs `conv` to subscribe.
    setup %{conv: conv} do
      {:ok, cw} = Magus.Chat.get_or_create_context_window(conv.id, actor: %AiAgent{})
      MagusWeb.Endpoint.subscribe("agents:#{conv.id}")
      %{cw: cw}
    end

    test "no-op path (<= tail messages) still broadcasts", %{cw: cw} do
      # No messages in the window -> RunCompaction settles :idle as a no-op.
      {:ok, updated} =
        cw
        |> Ash.Changeset.for_update(:mark_compacting, %{}, actor: %AiAgent{})
        |> Ash.update!()
        |> Ash.Changeset.for_update(:run_compaction, %{}, actor: %AiAgent{})
        |> Ash.update()

      assert updated.compaction_status == :idle

      assert_receive %Phoenix.Socket.Broadcast{
        event: "agent_signal",
        payload: %{type: "context.updated"}
      }
    end

    # The after_action broadcast is branch-agnostic: every settle path (no-op,
    # success, failure) shares the exact same after_action. The no-op path above
    # and the success path below both prove the broadcast fires; the failed branch
    # broadcasts through the identical code path. The :failed branch itself is
    # covered by compact_context_trigger_test.exs (summarizer returns an error).
    test "success path (summary stored) broadcasts", %{user: user, conv: conv, cw: cw} do
      k = Magus.Chat.ContextWindow.config(:compaction_tail)
      n = k + 2

      # Seed enough in-window messages that the older slice is summarized.
      # generate/1 inserts sequentially, so inserted_at is ascending.
      msgs =
        for i <- 1..n do
          generate(message(actor: user, conversation_id: conv.id, text: "msg #{i}"))
        end

      # Stub the summarizer so the success branch runs deterministically offline.
      # Mirrors compact_context_trigger_test.exs.
      expect(LLMMock, :generate_text, fn _model, _context, _opts ->
        MockResponses.generate_text_response("the stubbed summary")
      end)

      {:ok, updated} =
        cw
        |> Ash.Changeset.for_update(:mark_compacting, %{}, actor: %AiAgent{})
        |> Ash.update!()
        |> Ash.Changeset.for_update(:run_compaction, %{}, actor: %AiAgent{})
        |> Ash.update()

      # Success branch: summary stored, pointer advanced to the tail head, :idle.
      assert updated.compaction_status == :idle
      assert updated.summary == "the stubbed summary"
      assert updated.summary_message_count == n - k

      tail_head = Enum.at(msgs, n - k)
      assert updated.window_start_message_id == tail_head.id
      assert updated.window_start_at == tail_head.inserted_at

      assert_receive %Phoenix.Socket.Broadcast{
        event: "agent_signal",
        payload: %{type: "context.updated"}
      }
    end
  end

  # ============================================================================
  # :compact_context trigger reclaims :pending rows (the only in-flight state the
  # trigger path produces). There is no claim-to-:running step in production, so
  # the cron only needs to reclaim :pending rows that missed their on-demand
  # enqueue. Settled rows (:idle / :failed) must NOT be reclaimed.
  # ============================================================================

  describe "compact_context trigger reclaim filter" do
    setup %{conv: conv} do
      {:ok, cw} = Magus.Chat.get_or_create_context_window(conv.id, actor: %AiAgent{})
      %{cw: cw}
    end

    test "the trigger where reclaims a :pending row", %{cw: cw} do
      {:ok, _pending} =
        Magus.Chat.request_context_compaction(cw, %{}, authorize?: false)

      # This filter hand-mirrors the :compact_context trigger `where` in
      # context_window.ex. Keep it in sync if the trigger `where` changes.
      ready =
        Magus.Chat.ContextWindow
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(compaction_status == :pending)
        |> Ash.read!(authorize?: false)

      assert Enum.any?(ready, &(&1.id == cw.id))
    end

    test "a settled :idle row is NOT reclaimed by the filter", %{cw: cw} do
      # get_or_create leaves the row at :idle (the default settled state).
      assert cw.compaction_status == :idle

      ready =
        Magus.Chat.ContextWindow
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(compaction_status == :pending)
        |> Ash.read!(authorize?: false)

      refute Enum.any?(ready, &(&1.id == cw.id))
    end

    test "a settled :failed row is NOT reclaimed by the filter", %{cw: cw} do
      {:ok, _failed} =
        Magus.Chat.mark_context_compaction_failed(cw, %{}, actor: %AiAgent{})

      ready =
        Magus.Chat.ContextWindow
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(compaction_status == :pending)
        |> Ash.read!(authorize?: false)

      refute Enum.any?(ready, &(&1.id == cw.id))
    end
  end
end
