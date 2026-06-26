defmodule MagusWeb.Workbench.Resources.PromptViewTest do
  use MagusWeb.LiveViewCase, async: false
  import MagusWeb.LiveViewCase
  import Magus.Generators

  alias MagusWeb.Workbench.Resources.PromptView

  test "renders the prompt's name and content" do
    user = generate(user())

    {:ok, prompt} =
      Magus.Library.create_prompt(
        %{name: "Summarize", content: "Please summarize the following text:", type: :user},
        actor: user
      )

    {:ok, _lv, html} =
      Phoenix.LiveViewTest.live_isolated(
        Phoenix.ConnTest.build_conn(),
        PromptView,
        session: %{
          "prompt_id" => prompt.id,
          "user_id" => user.id
        }
      )

    assert html =~ "Summarize"
    assert html =~ "Please summarize"
    assert html =~ ~s(data-prompt-view)
  end

  test "renders not-found state when prompt is missing" do
    user = generate(user())

    {:ok, _lv, html} =
      Phoenix.LiveViewTest.live_isolated(
        Phoenix.ConnTest.build_conn(),
        PromptView,
        session: %{
          "prompt_id" => Ecto.UUID.generate(),
          "user_id" => user.id
        }
      )

    assert html =~ "not found"
  end

  # ---------------------------------------------------------------------------
  # Edit mode tests (session-based: simulate what TabContainer passes)
  # ---------------------------------------------------------------------------

  describe "prompt edit mode via session" do
    setup do
      user = generate(user())

      {:ok, prompt} =
        Magus.Library.create_prompt(
          %{name: "Edit me", content: "do things", type: :user},
          actor: user
        )

      %{user: user, prompt: prompt}
    end

    test "defaults to inspect mode (no edit form)", %{user: user, prompt: prompt} do
      {:ok, _lv, html} =
        Phoenix.LiveViewTest.live_isolated(
          Phoenix.ConnTest.build_conn(),
          PromptView,
          session: %{"prompt_id" => prompt.id, "user_id" => user.id}
        )

      refute html =~ ~s(data-prompt-edit)
    end

    test "renders edit form when session has edit=true", %{user: user, prompt: prompt} do
      {:ok, _lv, html} =
        Phoenix.LiveViewTest.live_isolated(
          Phoenix.ConnTest.build_conn(),
          PromptView,
          session: %{
            "prompt_id" => prompt.id,
            "user_id" => user.id,
            "edit" => "true"
          }
        )

      assert html =~ ~s(data-prompt-edit)
    end

    test "enter_edit event switches to edit form", %{user: user, prompt: prompt} do
      {:ok, lv, html} =
        Phoenix.LiveViewTest.live_isolated(
          Phoenix.ConnTest.build_conn(),
          PromptView,
          session: %{"prompt_id" => prompt.id, "user_id" => user.id}
        )

      refute html =~ ~s(data-prompt-edit)

      html = Phoenix.LiveViewTest.render_click(lv, "enter_edit")
      assert html =~ ~s(data-prompt-edit)
    end

    test "exit_edit event returns to inspect view", %{user: user, prompt: prompt} do
      {:ok, lv, _html} =
        Phoenix.LiveViewTest.live_isolated(
          Phoenix.ConnTest.build_conn(),
          PromptView,
          session: %{
            "prompt_id" => prompt.id,
            "user_id" => user.id,
            "edit" => "true"
          }
        )

      html = Phoenix.LiveViewTest.render_click(lv, "exit_edit")
      refute html =~ ~s(data-prompt-edit)
    end
  end

  # ---------------------------------------------------------------------------
  # Redirect tests
  # ---------------------------------------------------------------------------

  describe "legacy route redirects" do
    setup %{conn: conn} do
      user = generate(user())
      conn = log_in_user(conn, user)

      {:ok, prompt} =
        Magus.Library.create_prompt(
          %{name: "P", content: "c", type: :user},
          actor: user
        )

      %{conn: conn, prompt: prompt}
    end

    test "redirects /prompts/:id/edit to /prompts_library/:id?edit=true", %{
      conn: conn,
      prompt: prompt
    } do
      conn = get(conn, "/prompts/#{prompt.id}/edit")
      assert redirected_to(conn) =~ "edit=true"
      assert redirected_to(conn) =~ "/prompts_library/#{prompt.id}"
    end
  end
end
