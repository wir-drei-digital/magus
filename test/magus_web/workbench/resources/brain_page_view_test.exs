defmodule MagusWeb.Workbench.Resources.BrainPageViewTest do
  use MagusWeb.LiveViewCase, async: false
  import Magus.Generators
  import MagusWeb.Workbench.TestHelpers

  alias MagusWeb.Workbench.Resources.BrainPageView
  alias MagusWeb.Workbench.Signals, as: WorkbenchSignals

  test "mounts with a brain page loaded" do
    user = generate(user())
    ensure_workspace_plan(user)
    ws = generate(workspace(actor: user))

    {:ok, brain} =
      Magus.Brain.create_brain(%{title: "Test brain", workspace_id: ws.id}, actor: user)

    {:ok, page} =
      Magus.Brain.create_page(brain.id, %{title: "Test page"}, actor: user)

    {:ok, _lv, html} =
      Phoenix.LiveViewTest.live_isolated(
        Phoenix.ConnTest.build_conn(),
        BrainPageView,
        session: %{
          "page_id" => page.id,
          "user_id" => user.id,
          "tab_id" => "tab_brain"
        }
      )

    assert html =~ page.title
  end

  # magus-gw1: a freshly created page has `body: nil`. It must render the
  # editor (not the "Page is being prepared" placeholder) so the user can type
  # into it, and the first save must succeed.
  test "a fresh empty page renders the editor and is user-editable" do
    user = generate(user())
    ensure_workspace_plan(user)

    {:ok, brain} = Magus.Brain.create_brain(%{title: "B"}, actor: user)
    {:ok, page} = Magus.Brain.create_page(brain.id, %{title: "Fresh"}, actor: user)

    # Precondition: a brand-new page genuinely has no body.
    assert is_nil(page.body)

    {:ok, view, html} =
      Phoenix.LiveViewTest.live_isolated(
        Phoenix.ConnTest.build_conn(),
        BrainPageView,
        session: %{
          "page_id" => page.id,
          "user_id" => user.id,
          "tab_id" => "tab_brain_empty"
        }
      )

    # Editor mounts; the obsolete placeholder is gone.
    assert html =~ ~s(phx-hook="BrainTiptapEditor")
    assert html =~ "brain-editor-#{page.id}"
    refute html =~ "data-brain-editor-placeholder"
    refute html =~ "Page is being prepared"

    # First save from the empty editor persists and replies with the
    # authoritative bumped lock_version.
    json = %{
      "type" => "doc",
      "content" => [
        %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "first words"}]}
      ]
    }

    Phoenix.LiveViewTest.render_hook(view, "brain_editor_save", %{
      "prosemirror" => json,
      "base_version" => page.lock_version
    })

    assert_reply(view, %{ok: true, lock_version: lock_version})
    assert lock_version == page.lock_version + 1

    {:ok, reloaded} = Magus.Brain.get_page(page.id, actor: user)
    assert reloaded.body =~ "first words"
  end

  test "brain_editor_save accepts ProseMirror JSON and persists markdown" do
    user = generate(user())
    ensure_workspace_plan(user)

    {:ok, brain} = Magus.Brain.create_brain(%{title: "B"}, actor: user)
    {:ok, page} = Magus.Brain.create_page(brain.id, %{title: "P"}, actor: user)

    {:ok, page} =
      Magus.Brain.update_page_body(
        page,
        %{body: "start", base_version: page.lock_version},
        actor: user
      )

    {:ok, view, _html} =
      Phoenix.LiveViewTest.live_isolated(
        Phoenix.ConnTest.build_conn(),
        BrainPageView,
        session: %{
          "page_id" => page.id,
          "user_id" => user.id,
          "tab_id" => "tab_brain_save_pm"
        }
      )

    json = %{
      "type" => "doc",
      "content" => [
        %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "updated"}]}
      ]
    }

    Phoenix.LiveViewTest.render_hook(view, "brain_editor_save", %{
      "prosemirror" => json,
      "base_version" => page.lock_version
    })

    {:ok, reloaded} = Magus.Brain.get_page(page.id, actor: user)
    assert reloaded.body == "updated"
  end

  # EVIDENCE (magus-t12): a self-save must NOT push brain:reload_body back to
  # the same editor. The view subscribes to its own brain/page topics, so its
  # own update_body broadcast (page.body_updated) loops back. If self_echo?
  # fails to recognise it, the hook runs setContent() and the caret jumps to
  # the document end.
  test "self-save does NOT push brain:reload_body (self-echo suppression)" do
    user = generate(user())
    ensure_workspace_plan(user)

    {:ok, brain} = Magus.Brain.create_brain(%{title: "B"}, actor: user)
    {:ok, page} = Magus.Brain.create_page(brain.id, %{title: "P"}, actor: user)

    {:ok, page} =
      Magus.Brain.update_page_body(
        page,
        %{body: "start", base_version: page.lock_version},
        actor: user
      )

    {:ok, view, _html} =
      Phoenix.LiveViewTest.live_isolated(
        Phoenix.ConnTest.build_conn(),
        BrainPageView,
        session: %{
          "page_id" => page.id,
          "user_id" => user.id,
          "tab_id" => "tab_brain_self_echo"
        }
      )

    json = %{
      "type" => "doc",
      "content" => [
        %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "updated body"}]}
      ]
    }

    Phoenix.LiveViewTest.render_hook(view, "brain_editor_save", %{
      "prosemirror" => json,
      "base_version" => page.lock_version
    })

    # Flush the LV mailbox so the self-broadcast (page.body_updated) is
    # processed before we assert on pushed events.
    _ = Phoenix.LiveViewTest.render(view)

    refute_push_event(view, "brain:reload_body", %{})
    refute_push_event(view, "brain:conflict_overwrite", %{})
  end

  # POSITIVE CONTROL (magus-t12): a genuinely remote body update (different
  # actor, higher lock_version, editor not dirty) MUST push brain:reload_body.
  # Proves the reload mechanism is observable in the test harness, so the
  # refute above is meaningful (not a false negative).
  test "remote body update DOES push brain:reload_body" do
    user = generate(user())
    ensure_workspace_plan(user)

    {:ok, brain} = Magus.Brain.create_brain(%{title: "B"}, actor: user)
    {:ok, page} = Magus.Brain.create_page(brain.id, %{title: "P"}, actor: user)

    {:ok, page} =
      Magus.Brain.update_page_body(
        page,
        %{body: "start", base_version: page.lock_version},
        actor: user
      )

    {:ok, view, _html} =
      Phoenix.LiveViewTest.live_isolated(
        Phoenix.ConnTest.build_conn(),
        BrainPageView,
        session: %{
          "page_id" => page.id,
          "user_id" => user.id,
          "tab_id" => "tab_brain_remote"
        }
      )

    send(
      view.pid,
      %Phoenix.Socket.Broadcast{
        topic: "brain:#{brain.id}",
        event: "page.body_updated",
        payload: %{
          record: page,
          brain_id: brain.id,
          body: "remote edit",
          lock_version: page.lock_version + 5,
          modified_at: DateTime.utc_now(),
          actor_id: Ash.UUID.generate(),
          source: :user
        }
      }
    )

    _ = Phoenix.LiveViewTest.render(view)
    assert_push_event(view, "brain:reload_body", %{})
  end

  # EVIDENCE (magus-t12): replicate continuous typing — several consecutive
  # autosaves where the client advances base_version optimistically (+1 per
  # save, mirroring the JS hook). If lock_version drifts between client and
  # server, a later save conflicts and pushes conflict_overwrite/reload_body
  # → setContent → caret jumps. Assert it never does.
  test "consecutive self-saves never push reload_body/conflict (no lock drift)" do
    user = generate(user())
    ensure_workspace_plan(user)

    {:ok, brain} = Magus.Brain.create_brain(%{title: "B"}, actor: user)
    {:ok, page} = Magus.Brain.create_page(brain.id, %{title: "P"}, actor: user)

    {:ok, page} =
      Magus.Brain.update_page_body(
        page,
        %{body: "start", base_version: page.lock_version},
        actor: user
      )

    {:ok, view, _html} =
      Phoenix.LiveViewTest.live_isolated(
        Phoenix.ConnTest.build_conn(),
        BrainPageView,
        session: %{
          "page_id" => page.id,
          "user_id" => user.id,
          "tab_id" => "tab_brain_multi"
        }
      )

    # Client mirrors the JS hook: starts at the mounted lock_version and
    # increments by 1 after each accepted save.
    for n <- 1..5 do
      base = page.lock_version + (n - 1)

      json = %{
        "type" => "doc",
        "content" => [
          %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "edit #{n}"}]}
        ]
      }

      Phoenix.LiveViewTest.render_hook(view, "brain_editor_save", %{
        "prosemirror" => json,
        "base_version" => base
      })

      _ = Phoenix.LiveViewTest.render(view)
    end

    refute_push_event(view, "brain:reload_body", %{})
    refute_push_event(view, "brain:conflict_overwrite", %{})

    {:ok, reloaded} = Magus.Brain.get_page(page.id, actor: user)
    assert reloaded.body == "edit 5"
  end

  # ROOT CAUSE (magus-t12): the JS hook's save callback expects a reply of
  # `{ok: true, lock_version: N}` (success) or `{ok: false}` (conflict) so it
  # can sync its client-side lock_version to the server's authority. If the
  # server returns {:noreply} the client falls back to an optimistic `+1`,
  # which is correct on success but WRONG on conflict (the conflict_overwrite
  # handler sets the version, then the save callback corrupts it with +1) —
  # producing a permanent desync where every later autosave conflicts and
  # setContent jumps the caret to the document end.
  test "brain_editor_save replies {ok: true, lock_version} on success" do
    user = generate(user())
    ensure_workspace_plan(user)

    {:ok, brain} = Magus.Brain.create_brain(%{title: "B"}, actor: user)
    {:ok, page} = Magus.Brain.create_page(brain.id, %{title: "P"}, actor: user)

    {:ok, page} =
      Magus.Brain.update_page_body(
        page,
        %{body: "start", base_version: page.lock_version},
        actor: user
      )

    {:ok, view, _html} =
      Phoenix.LiveViewTest.live_isolated(
        Phoenix.ConnTest.build_conn(),
        BrainPageView,
        session: %{
          "page_id" => page.id,
          "user_id" => user.id,
          "tab_id" => "tab_brain_reply_ok"
        }
      )

    json = %{
      "type" => "doc",
      "content" => [
        %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "updated"}]}
      ]
    }

    Phoenix.LiveViewTest.render_hook(view, "brain_editor_save", %{
      "prosemirror" => json,
      "base_version" => page.lock_version
    })

    assert_reply(view, %{ok: true, lock_version: lock_version})
    assert lock_version == page.lock_version + 1
  end

  test "brain_editor_save replies {ok: false} on version conflict (no client +1 corruption)" do
    user = generate(user())
    ensure_workspace_plan(user)

    {:ok, brain} = Magus.Brain.create_brain(%{title: "B"}, actor: user)
    {:ok, page} = Magus.Brain.create_page(brain.id, %{title: "P"}, actor: user)

    {:ok, page} =
      Magus.Brain.update_page_body(
        page,
        %{body: "start", base_version: page.lock_version},
        actor: user
      )

    {:ok, view, _html} =
      Phoenix.LiveViewTest.live_isolated(
        Phoenix.ConnTest.build_conn(),
        BrainPageView,
        session: %{
          "page_id" => page.id,
          "user_id" => user.id,
          "tab_id" => "tab_brain_reply_conflict"
        }
      )

    json = %{
      "type" => "doc",
      "content" => [
        %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => "racing edit"}]}
      ]
    }

    # Stale base_version (client thinks it's a version behind) => conflict.
    Phoenix.LiveViewTest.render_hook(view, "brain_editor_save", %{
      "prosemirror" => json,
      "base_version" => page.lock_version - 1
    })

    assert_push_event(view, "brain:conflict_overwrite", %{current_version: _})
    assert_reply(view, %{ok: false})
  end

  test "renders without crashing when the assigned page lacks the :prosemirror calc" do
    user = generate(user())
    ensure_workspace_plan(user)

    {:ok, brain} = Magus.Brain.create_brain(%{title: "B"}, actor: user)
    {:ok, page} = Magus.Brain.create_page(brain.id, %{title: "P"}, actor: user)

    {:ok, page} =
      Magus.Brain.update_page_body(
        page,
        %{body: "hello world", base_version: page.lock_version},
        actor: user
      )

    {:ok, view, _html} =
      Phoenix.LiveViewTest.live_isolated(
        Phoenix.ConnTest.build_conn(),
        BrainPageView,
        session: %{
          "page_id" => page.id,
          "user_id" => user.id,
          "tab_id" => "tab_brain_notloaded"
        }
      )

    # A `page.updated` broadcast assigns the broadcast record, whose
    # `:prosemirror` calculation is NOT loaded. Rendering the editor must fall
    # back to converting the body rather than crashing on
    # `Jason.encode!(%Ash.NotLoaded{})` (regression: C2). Fetch without the
    # calc so prosemirror is genuinely NotLoaded.
    {:ok, fresh} = Magus.Brain.get_page(page.id, actor: user)
    assert match?(%Ash.NotLoaded{}, fresh.prosemirror)

    send(
      view.pid,
      %Phoenix.Socket.Broadcast{
        topic: "brain:#{brain.id}",
        event: "page.updated",
        payload: %{page: fresh}
      }
    )

    html = Phoenix.LiveViewTest.render(view)
    assert html =~ "data-content"
  end

  describe "open_companion_chat" do
    test "find_or_create_companion_conversation returns the same conversation on second call" do
      user = generate(user())
      ensure_workspace_plan(user)

      {:ok, brain} = Magus.Brain.create_brain(%{title: "B"}, actor: user)
      {:ok, page} = Magus.Brain.create_page(brain.id, %{title: "P"}, actor: user)

      {:ok, conv1} =
        Magus.Chat.find_or_create_companion_conversation(:brain_page, page.id, actor: user)

      {:ok, conv2} =
        Magus.Chat.find_or_create_companion_conversation(:brain_page, page.id, actor: user)

      assert conv1.id == conv2.id
    end

    test "Open chat button hidden when role == companion" do
      user = generate(user())
      ensure_workspace_plan(user)

      {:ok, brain} = Magus.Brain.create_brain(%{title: "Brain"}, actor: user)
      {:ok, page} = Magus.Brain.create_page(brain.id, %{title: "Page"}, actor: user)

      {:ok, _view, html} =
        Phoenix.LiveViewTest.live_isolated(
          Phoenix.ConnTest.build_conn(),
          BrainPageView,
          session: %{
            "page_id" => page.id,
            "user_id" => user.id,
            "tab_id" => "tab_brain_companion_role",
            "role" => "companion"
          }
        )

      refute html =~ ~s(data-brain-open-chat)
      assert html =~ ~s(phx-click="close_self_companion")
    end

    test "close_self_companion broadcasts close on the tab topic" do
      user = generate(user())
      ensure_workspace_plan(user)

      {:ok, brain} = Magus.Brain.create_brain(%{title: "Brain"}, actor: user)
      {:ok, page} = Magus.Brain.create_page(brain.id, %{title: "Page"}, actor: user)

      tab_id = "tab_brain_close_self_#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Magus.PubSub, WorkbenchSignals.tab_topic(tab_id))

      {:ok, view, _html} =
        Phoenix.LiveViewTest.live_isolated(
          Phoenix.ConnTest.build_conn(),
          BrainPageView,
          session: %{
            "page_id" => page.id,
            "user_id" => user.id,
            "tab_id" => tab_id,
            "role" => "companion"
          }
        )

      view
      |> Phoenix.LiveViewTest.element(~s(button[phx-click="close_self_companion"]))
      |> Phoenix.LiveViewTest.render_click()

      assert_receive {:workbench_companion, :close}, 500
    end

    test "open chat reopens the same companion after the companion closes" do
      user = generate(user())
      ensure_workspace_plan(user)

      {:ok, brain} = Magus.Brain.create_brain(%{title: "Brain"}, actor: user)

      {:ok, page} =
        Magus.Brain.create_page(brain.id, %{title: "Page"}, actor: user)

      tab_id = "tab_brain_companion_test"
      Phoenix.PubSub.subscribe(Magus.PubSub, WorkbenchSignals.tab_topic(tab_id))

      {:ok, view, _html} =
        Phoenix.LiveViewTest.live_isolated(
          Phoenix.ConnTest.build_conn(),
          BrainPageView,
          session: %{
            "page_id" => page.id,
            "user_id" => user.id,
            "tab_id" => tab_id
          }
        )

      view
      |> Phoenix.LiveViewTest.element(~s(button[data-brain-open-chat]))
      |> Phoenix.LiveViewTest.render_click()

      assert_receive {:workbench_companion,
                      {:open, %{"type" => "conversation", "id" => first_id}}}

      :ok = poll_until(fn -> render(view) =~ ~s(data-brain-open-chat) == false end)

      WorkbenchSignals.broadcast_close_companion(tab_id)
      assert_receive {:workbench_companion, :close}

      :ok = poll_until(fn -> render(view) =~ ~s(data-brain-open-chat) end)

      view
      |> Phoenix.LiveViewTest.element(~s(button[data-brain-open-chat]))
      |> Phoenix.LiveViewTest.render_click()

      assert_receive {:workbench_companion,
                      {:open, %{"type" => "conversation", "id" => second_id}}}

      assert first_id == second_id
    end
  end

  describe "link_brain_file (sidebar drag)" do
    test "links a same-workspace file by appending a magus://file/<id> link to body" do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      {:ok, brain} =
        Magus.Brain.create_brain(%{title: "Brain", workspace_id: ws.id}, actor: user)

      {:ok, page} = Magus.Brain.create_page(brain.id, %{title: "Page"}, actor: user)

      {:ok, file} =
        Magus.Files.create_file(
          %{
            name: "doc.pdf",
            type: :document,
            mime_type: "application/pdf",
            file_size: 1024,
            file_path: "tmp/doc.pdf",
            workspace_id: ws.id
          },
          actor: user
        )

      tab_id = "tab_brain_link_file_#{System.unique_integer([:positive])}"

      {:ok, view, _html} =
        Phoenix.LiveViewTest.live_isolated(
          Phoenix.ConnTest.build_conn(),
          BrainPageView,
          session: %{
            "page_id" => page.id,
            "user_id" => user.id,
            "tab_id" => tab_id,
            "role" => "primary"
          }
        )

      Phoenix.LiveViewTest.render_hook(view, "link_brain_file", %{"file_id" => file.id})

      {:ok, reloaded} = Magus.Brain.get_page(page.id, actor: user)
      assert reloaded.body =~ "magus://file/#{file.id}"
    end

    test "cross-workspace file link is rejected (body unchanged, flash error set)" do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))
      other_ws = generate(workspace(actor: user))

      {:ok, brain} =
        Magus.Brain.create_brain(%{title: "Brain", workspace_id: ws.id}, actor: user)

      {:ok, page} = Magus.Brain.create_page(brain.id, %{title: "Page"}, actor: user)

      {:ok, file} =
        Magus.Files.create_file(
          %{
            name: "doc.pdf",
            type: :document,
            mime_type: "application/pdf",
            file_size: 1024,
            file_path: "tmp/doc.pdf",
            workspace_id: other_ws.id
          },
          actor: user
        )

      tab_id = "tab_brain_link_file_xworkspace_#{System.unique_integer([:positive])}"

      {:ok, view, _html} =
        Phoenix.LiveViewTest.live_isolated(
          Phoenix.ConnTest.build_conn(),
          BrainPageView,
          session: %{
            "page_id" => page.id,
            "user_id" => user.id,
            "tab_id" => tab_id,
            "role" => "primary"
          }
        )

      Phoenix.LiveViewTest.render_hook(view, "link_brain_file", %{"file_id" => file.id})

      {:ok, reloaded} = Magus.Brain.get_page(page.id, actor: user)
      refute (reloaded.body || "") =~ "magus://file/#{file.id}"
    end
  end

  describe "file status broadcasts (loading-state-aware rendering)" do
    test "an `update` broadcast on the workspace files topic refreshes the file map and pushes brain:file-map-updated" do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      {:ok, brain} =
        Magus.Brain.create_brain(%{title: "Brain", workspace_id: ws.id}, actor: user)

      {:ok, page} = Magus.Brain.create_page(brain.id, %{title: "Page"}, actor: user)

      {:ok, file} =
        Magus.Files.create_file(
          %{
            name: "doc.pdf",
            type: :document,
            mime_type: "application/pdf",
            file_size: 1024,
            file_path: "tmp/doc.pdf",
            workspace_id: ws.id
          },
          actor: user
        )

      # File references live in the body. Seed a magus://file/<id> link so
      # the body file map picks the file up on mount.
      {:ok, _page} =
        Magus.Brain.update_page_body(
          page,
          %{body: "[📎 doc](magus://file/#{file.id})", base_version: page.lock_version},
          actor: user
        )

      tab_id = "tab_brain_file_status_#{System.unique_integer([:positive])}"

      {:ok, view, _html} =
        Phoenix.LiveViewTest.live_isolated(
          Phoenix.ConnTest.build_conn(),
          BrainPageView,
          session: %{
            "page_id" => page.id,
            "user_id" => user.id,
            "tab_id" => tab_id,
            "role" => "primary"
          }
        )

      # Ensure mount completed and file map populated.
      _ = Phoenix.LiveViewTest.render(view)

      # Simulate a file status update broadcast on the workspace files
      # topic. We don't send the full File record; the LV re-loads the
      # file map from the page body, so just the id is enough to trigger.
      MagusWeb.Endpoint.broadcast(
        "workspaces:#{ws.id}:files",
        "update",
        %{id: file.id, workspace_id: ws.id, action: :updated}
      )

      # Allow the broadcast to be processed; render forces a flush.
      _html = Phoenix.LiveViewTest.render(view)

      # Verify the LV pushed a brain:file-map-updated event by checking
      # one was pushed. LiveView surfaces server pushes via render_hook
      # event capture; here we use the assert_push_event idiom.
      assert_push_event(view, "brain:file-map-updated", %{file_map: file_map})

      assert is_map(file_map)
      assert Map.has_key?(file_map, file.id)
    end
  end

  describe "page references" do
    test "starts with an empty page list, pushes sibling pages async, and opens refs by title" do
      user = generate(user())
      ensure_workspace_plan(user)

      {:ok, brain} = Magus.Brain.create_brain(%{title: "Brain"}, actor: user)
      {:ok, page} = Magus.Brain.create_page(brain.id, %{title: "Page"}, actor: user)
      {:ok, sibling} = Magus.Brain.create_page(brain.id, %{title: "Sibling"}, actor: user)

      Phoenix.PubSub.subscribe(Magus.PubSub, "workbench-tabs:#{user.id}")

      {:ok, view, html} =
        Phoenix.LiveViewTest.live_isolated(
          Phoenix.ConnTest.build_conn(),
          BrainPageView,
          session: %{"page_id" => page.id, "user_id" => user.id, "tab_id" => "tab_refs"}
        )

      assert html =~ ~s(data-pages="[]")

      assert_push_event(view, "brain:update_pages", %{pages: pages})

      assert Enum.any?(pages, fn page ->
               page.id == sibling.id and page.title == sibling.title
             end)

      Phoenix.LiveViewTest.render_hook(view, "brain:open_page_ref", %{"title" => sibling.title})

      assert_receive {:open_brain_page_in_new_tab, page_id}, 500
      assert page_id == sibling.id
    end
  end

  describe "sources tab (page-scoped)" do
    test "lists only this page's sources as external links" do
      user = generate(user())
      ensure_workspace_plan(user)

      {:ok, brain} = Magus.Brain.create_brain(%{title: "Brain"}, actor: user)
      {:ok, page} = Magus.Brain.create_page(brain.id, %{title: "Page"}, actor: user)

      body = "# T\n\n```source\nurl: https://example.com\ntitle: Example\n```\n"

      {:ok, _} =
        Magus.Brain.update_page_body(
          page,
          %{body: body, base_version: page.lock_version},
          actor: user
        )

      {:ok, view, html} =
        Phoenix.LiveViewTest.live_isolated(
          Phoenix.ConnTest.build_conn(),
          BrainPageView,
          session: %{"page_id" => page.id, "user_id" => user.id, "tab_id" => "tab_src"}
        )

      refute html =~ ~s(data-brain-source-id)

      view
      |> Phoenix.LiveViewTest.element(~s(button[phx-value-tab="sources"]))
      |> Phoenix.LiveViewTest.render_click()

      html = Phoenix.LiveViewTest.render(view)
      assert html =~ ~s(data-brain-source-id)
      assert html =~ ~s(href="https://example.com")
      assert html =~ ~s(target="_blank")
    end
  end

  describe "outline tab (scroll-to-block wiring)" do
    test "each heading row carries a data-heading-index and the scroll hook is wired" do
      user = generate(user())
      ensure_workspace_plan(user)

      {:ok, brain} = Magus.Brain.create_brain(%{title: "Brain"}, actor: user)
      {:ok, page} = Magus.Brain.create_page(brain.id, %{title: "Page"}, actor: user)

      {:ok, _} =
        Magus.Brain.update_page_body(
          page,
          %{body: "# One\n\ntext\n\n## Two\n", base_version: page.lock_version},
          actor: user
        )

      {:ok, view, _html} =
        Phoenix.LiveViewTest.live_isolated(
          Phoenix.ConnTest.build_conn(),
          BrainPageView,
          session: %{"page_id" => page.id, "user_id" => user.id, "tab_id" => "tab_outline"}
        )

      view
      |> Phoenix.LiveViewTest.element(~s(button[phx-value-tab="outline"]))
      |> Phoenix.LiveViewTest.render_click()

      html = Phoenix.LiveViewTest.render(view)
      assert html =~ ~s(data-heading-index="0")
      assert html =~ ~s(data-heading-index="1")
      # phx-hook=".OutlineScroll" is expanded at compile time to the fully-qualified module name
      assert html =~
               ~s(phx-hook="MagusWeb.ChatLive.Components.Brain.BrainPaneComponent.OutlineScroll")
    end
  end

  describe "activity tab (page history)" do
    test "lists this page's versions with data-brain-version-id" do
      user = generate(user())
      ensure_workspace_plan(user)

      {:ok, brain} = Magus.Brain.create_brain(%{title: "Brain"}, actor: user)
      {:ok, page} = Magus.Brain.create_page(brain.id, %{title: "Page"}, actor: user)

      {:ok, p1} =
        Magus.Brain.update_page_body(
          page,
          %{body: "first", base_version: page.lock_version},
          actor: user
        )

      {:ok, _p2} =
        Magus.Brain.update_page_body(
          p1,
          %{body: "second", base_version: p1.lock_version},
          actor: user
        )

      {:ok, view, html} =
        Phoenix.LiveViewTest.live_isolated(
          Phoenix.ConnTest.build_conn(),
          BrainPageView,
          session: %{"page_id" => page.id, "user_id" => user.id, "tab_id" => "tab_act"}
        )

      refute html =~ ~s(data-brain-version-id)

      view
      |> Phoenix.LiveViewTest.element(~s(button[phx-value-tab="activity"]))
      |> Phoenix.LiveViewTest.render_click()

      [latest | _] = Magus.Brain.list_page_versions(page.id)
      html = Phoenix.LiveViewTest.render(view)
      assert html =~ ~s(data-brain-version-id="#{latest.version_id}")
    end
  end

  describe "version viewer + restore" do
    setup do
      user = generate(user())
      ensure_workspace_plan(user)

      {:ok, brain} = Magus.Brain.create_brain(%{title: "Brain"}, actor: user)
      {:ok, page} = Magus.Brain.create_page(brain.id, %{title: "Page"}, actor: user)

      {:ok, p1} =
        Magus.Brain.update_page_body(
          page,
          %{body: "alpha body", base_version: page.lock_version},
          actor: user
        )

      {:ok, _p2} =
        Magus.Brain.update_page_body(
          p1,
          %{body: "beta body", base_version: p1.lock_version},
          actor: user
        )

      {:ok, view, _html} =
        Phoenix.LiveViewTest.live_isolated(
          Phoenix.ConnTest.build_conn(),
          BrainPageView,
          session: %{"page_id" => page.id, "user_id" => user.id, "tab_id" => "tab_vv"}
        )

      view
      |> Phoenix.LiveViewTest.element(~s(button[phx-value-tab="activity"]))
      |> Phoenix.LiveViewTest.render_click()

      %{user: user, page: page, view: view}
    end

    test "clicking a version opens the diff overlay", %{view: view, page: page} do
      [latest | _] = Magus.Brain.list_page_versions(page.id)

      view
      |> Phoenix.LiveViewTest.element(~s(button[data-brain-version-id="#{latest.version_id}"]))
      |> Phoenix.LiveViewTest.render_click()

      html = Phoenix.LiveViewTest.render(view)
      assert html =~ ~s(data-brain-version-overlay)
    end

    test "restoring an older version writes its body back and closes the overlay", %{
      view: view,
      page: page,
      user: user
    } do
      # Target the "alpha body" edit explicitly rather than relying on
      # ordinal position (the version list also includes the :create snapshot).
      versions = Magus.Brain.list_page_versions(page.id)

      older =
        Enum.find(versions, fn v ->
          {:ok, body} = Magus.Brain.page_version_body(page.id, v.version_id)
          body =~ "alpha body"
        end)

      view
      |> Phoenix.LiveViewTest.element(~s(button[data-brain-version-id="#{older.version_id}"]))
      |> Phoenix.LiveViewTest.render_click()

      view
      |> Phoenix.LiveViewTest.element(~s(button[data-brain-version-restore]))
      |> Phoenix.LiveViewTest.render_click()

      html = Phoenix.LiveViewTest.render(view)
      refute html =~ ~s(data-brain-version-overlay)

      {:ok, reloaded} = Magus.Brain.get_page(page.id, actor: user)
      assert reloaded.body =~ "alpha body"
    end
  end

  describe "related tab navigation" do
    test "clicking a backlink opens that page in a new workbench tab" do
      user = generate(user())
      ensure_workspace_plan(user)

      {:ok, brain} = Magus.Brain.create_brain(%{title: "Brain"}, actor: user)
      {:ok, target} = Magus.Brain.create_page(brain.id, %{title: "Target"}, actor: user)
      {:ok, other} = Magus.Brain.create_page(brain.id, %{title: "Other"}, actor: user)

      # `[[Target]]` in Other's body creates a backlink Target <- Other.
      {:ok, _} =
        Magus.Brain.update_page_body(
          other,
          %{body: "see [[Target]]", base_version: other.lock_version},
          actor: user
        )

      Phoenix.PubSub.subscribe(Magus.PubSub, "workbench-tabs:#{user.id}")

      {:ok, view, html} =
        Phoenix.LiveViewTest.live_isolated(
          Phoenix.ConnTest.build_conn(),
          BrainPageView,
          session: %{"page_id" => target.id, "user_id" => user.id, "tab_id" => "tab_rel"}
        )

      refute html =~ ~s(data-brain-related-id="#{other.id}")

      view
      |> Phoenix.LiveViewTest.element(~s(button[phx-value-tab="related"]))
      |> Phoenix.LiveViewTest.render_click()

      view
      |> Phoenix.LiveViewTest.element(~s([data-brain-related-id="#{other.id}"]))
      |> Phoenix.LiveViewTest.render_click()

      assert_receive {:open_brain_page_in_new_tab, page_id}, 500
      assert page_id == other.id
    end
  end

  describe "open_brain_file routing" do
    setup do
      user = generate(user())
      ensure_workspace_plan(user)

      {:ok, brain} = Magus.Brain.create_brain(%{title: "Brain"}, actor: user)
      {:ok, page} = Magus.Brain.create_page(brain.id, %{title: "Page"}, actor: user)

      {:ok, file} =
        Magus.Files.create_file(
          %{
            name: "doc.pdf",
            type: :document,
            mime_type: "application/pdf",
            file_size: 1024,
            file_path: "tmp/doc.pdf",
            workspace_id: nil
          },
          actor: user
        )

      %{user: user, brain: brain, page: page, file_record: file}
    end

    test "primary role broadcasts companion-open on the tab topic", %{
      user: user,
      page: page,
      file_record: file
    } do
      tab_id = "tab_brain_open_file_primary_#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Magus.PubSub, WorkbenchSignals.tab_topic(tab_id))

      {:ok, view, _html} =
        Phoenix.LiveViewTest.live_isolated(
          Phoenix.ConnTest.build_conn(),
          BrainPageView,
          session: %{
            "page_id" => page.id,
            "user_id" => user.id,
            "tab_id" => tab_id,
            "role" => "primary"
          }
        )

      Phoenix.LiveViewTest.render_hook(view, "open_brain_file", %{
        "file_id" => file.id,
        "tab_role" => "primary"
      })

      assert_receive {:workbench_companion, {:open, %{"type" => "pdf", "id" => file_id}}}, 500
      assert file_id == file.id
    end

    test "companion role broadcasts open_file_in_new_tab on workbench-tabs topic", %{
      user: user,
      page: page,
      file_record: file
    } do
      tab_id = "tab_brain_open_file_companion_#{System.unique_integer([:positive])}"
      Phoenix.PubSub.subscribe(Magus.PubSub, "workbench-tabs:#{user.id}")

      {:ok, view, _html} =
        Phoenix.LiveViewTest.live_isolated(
          Phoenix.ConnTest.build_conn(),
          BrainPageView,
          session: %{
            "page_id" => page.id,
            "user_id" => user.id,
            "tab_id" => tab_id,
            "role" => "companion"
          }
        )

      Phoenix.LiveViewTest.render_hook(view, "open_brain_file", %{
        "file_id" => file.id,
        "tab_role" => "companion"
      })

      assert_receive {:open_file_in_new_tab, file_id}, 500
      assert file_id == file.id
    end
  end

  describe "query-count regression (magus-9rt)" do
    # Counts repo queries fired while mounting the BrainPageView via
    # `live_isolated/3`, which runs BOTH the disconnected (static) mount and
    # the connected mount — i.e. the exact reload path the issue flags.
    #
    # The dominant historical cost was the authorization filter:
    # `BrainAccessFilter.accessible_brain_ids` ran ~5 uncached reads per
    # authorized read, and each mount pass performs several authorized reads
    # (get_page, sibling list, sources, related, ...). The mount now wraps
    # its whole load pass in `BrainAccessFilter.with_request_cache/1`,
    # collapsing the repeated access resolutions into one per pass, and the
    # sibling list selects only id+title instead of every column (incl. the
    # full markdown body of every sibling).
    #
    # Measured with this exact fixture (1 page + 6 large-bodied siblings):
    #   * pre-fix:  73 queries for the live_isolated mount
    #   * post-fix: 25 queries
    # The assertion below (<= 35) captures that >2x reduction with headroom
    # rather than pinning the exact number.
    test "connected mount issues a bounded number of repo queries" do
      user = generate(user())
      ensure_workspace_plan(user)

      {:ok, brain} = Magus.Brain.create_brain(%{title: "Perf brain"}, actor: user)
      {:ok, page} = Magus.Brain.create_page(brain.id, %{title: "Perf page"}, actor: user)

      # Several sibling pages with substantial bodies. Pre-fix, the sibling
      # list pulled every body; post-fix it selects only id+title.
      big_body = String.duplicate("lorem ipsum dolor sit amet ", 400)

      for n <- 1..6 do
        {:ok, sib} = Magus.Brain.create_page(brain.id, %{title: "Sibling #{n}"}, actor: user)

        {:ok, _} =
          Magus.Brain.update_page_body(
            sib,
            %{body: big_body, base_version: sib.lock_version},
            actor: user
          )
      end

      count =
        count_repo_queries(fn ->
          {:ok, _view, _html} =
            Phoenix.LiveViewTest.live_isolated(
              Phoenix.ConnTest.build_conn(),
              BrainPageView,
              session: %{
                "page_id" => page.id,
                "user_id" => user.id,
                "tab_id" => "tab_brain_perf_#{System.unique_integer([:positive])}"
              }
            )
        end)

      # Threshold sits well below the pre-fix 73 and above the observed
      # post-fix 25, proving the scoped cache + slim sibling load collapsed
      # the work without pinning an exact number.
      assert count <= 35,
             "live_isolated mount issued #{count} repo queries; expected <= 35 after the " <>
               "scope-cache + slim-sibling-load fix (magus-9rt) (pre-fix was 73, post-fix " <>
               "25). A regression here likely means the BrainAccessFilter request cache " <>
               "stopped covering the mount loads, or the sibling list went back to " <>
               "selecting full page bodies."
    end

    # Directly demonstrates the access-filter dedupe: five authorized
    # `get_page` reads for the SAME actor inside one `with_request_cache`
    # scope must resolve the accessible-brain-id set only once, so they
    # issue materially fewer queries than five unscoped reads.
    test "with_request_cache collapses repeated authorized reads (before/after)" do
      user = generate(user())
      ensure_workspace_plan(user)

      {:ok, brain} = Magus.Brain.create_brain(%{title: "Dedupe brain"}, actor: user)
      {:ok, page} = Magus.Brain.create_page(brain.id, %{title: "Dedupe page"}, actor: user)

      read_five = fn ->
        for _ <- 1..5 do
          {:ok, _} = Magus.Brain.get_page(page.id, actor: user)
        end
      end

      uncached = count_repo_queries(read_five)

      cached =
        count_repo_queries(fn ->
          Magus.Brain.Checks.BrainAccessFilter.with_request_cache(read_five)
        end)

      assert cached < uncached,
             "scoped reads (#{cached}) should issue fewer queries than unscoped reads " <>
               "(#{uncached}); the request cache is not deduping access resolution."
    end
  end

  # Counts `[:magus, :repo, :query]` telemetry events emitted while `fun`
  # runs. Handler is attached for the window only; all fixtures must be
  # created before calling. Works across processes (the LiveView runs in a
  # separate process under the shared Ecto sandbox), which is exactly why
  # we attach immediately around the measured region.
  defp count_repo_queries(fun) do
    counter = :counters.new(1, [:atomics])
    handler_id = "qcount-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:magus, :repo, :query],
      fn _event, _measurements, _metadata, _config ->
        :counters.add(counter, 1, 1)
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    :counters.get(counter, 1)
  end
end
