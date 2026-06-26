defmodule MagusWeb.E2E.ModelModeTest do
  @moduledoc """
  Browser-based E2E tests for model selection and chat mode switching.

  Tests the model selector dropdown (listing models, switching models) and
  mode toggle buttons (chat, search, image generation, video generation).
  All LLM calls are mocked — no API keys needed.
  """
  use MagusWeb.PlaywrightCase

  @moduletag :e2e

  # Force-open a DaisyUI dropdown by injecting a <style> tag into <head>.
  # DaisyUI focus-based dropdowns close when Playwright assertions cause focus loss.
  # LiveView morphdom patches can remove JS-added CSS classes and inline styles,
  # but it doesn't touch <head>, so injected <style> tags persist reliably.
  defp open_model_dropdown(conn) do
    {:ok, _} =
      PlaywrightEx.Frame.evaluate(conn.frame_id,
        expression: """
        (() => {
          if (!document.getElementById('__test-dropdown-override')) {
            const style = document.createElement('style');
            style.id = '__test-dropdown-override';
            style.textContent = `
              #model-selector-dropdown .dropdown-content {
                display: block !important;
                visibility: visible !important;
                opacity: 1 !important;
              }
            `;
            document.head.appendChild(style);
          }
          return 'opened';
        })()
        """,
        timeout: 5_000
      )

    conn
  end

  describe "model selection" do
    # TODO: Flaky — LiveView morphdom patches intermittently hide dropdown items
    # before Playwright can assert visibility. Needs a different interaction strategy.
    @tag :skip
    test "model selector shows available models", %{conn: conn} do
      model =
        generate(
          model(
            name: "Model Alpha",
            key: "test/alpha",
            active?: true
          )
        )

      user = generate(user()) |> confirm_user()
      setup_subscription_for_user(user)
      conversation = generate(conversation(actor: user, selected_model_id: model.id))

      stub(LLMMock, :stream_text, fn _model, _context, _opts ->
        MockResponses.stream_text_response("ok")
      end)

      conn
      |> authenticate(user)
      |> visit(~p"/chat/#{conversation.id}")
      |> assert_has("body .phx-connected")
      |> open_model_dropdown()
      |> assert_has("#model-selector-model-#{model.id}", text: "Model Alpha", timeout: 5_000)
      |> assert_has("#model-selector-model-auto", text: "Auto")
    end

    # TODO: Flaky — same morphdom/dropdown interaction issue as above
    @tag :skip
    test "switch model via dropdown", %{conn: conn} do
      model1 =
        generate(
          model(
            name: "Model Alpha",
            key: "test/alpha",
            active?: true
          )
        )

      model2 =
        generate(
          model(
            name: "Model Beta",
            key: "test/beta",
            active?: true
          )
        )

      user = generate(user()) |> confirm_user()
      setup_subscription_for_user(user)
      conversation = generate(conversation(actor: user, selected_model_id: model1.id))

      stub(LLMMock, :stream_text, fn _model, _context, _opts ->
        MockResponses.stream_text_response("ok")
      end)

      conn
      |> authenticate(user)
      |> visit(~p"/chat/#{conversation.id}")
      |> assert_has("body .phx-connected")
      |> open_model_dropdown()
      |> assert_has("#model-selector-model-#{model1.id}", text: "Model Alpha", timeout: 5_000)
      |> assert_has("#model-selector-model-#{model2.id}", text: "Model Beta", timeout: 5_000)
      |> click("#model-selector-model-#{model1.id}")
      |> assert_has("#model-selector-dropdown [role='button']",
        text: "Model Alpha",
        timeout: 5_000
      )
      |> open_model_dropdown()
      |> click("#model-selector-model-#{model2.id}")
      |> assert_has("#model-selector-dropdown [role='button']",
        text: "Model Beta",
        timeout: 5_000
      )
    end
  end

  describe "chat modes" do
    test "mode toggle buttons are visible", %{conn: conn} do
      model = create_default_model()
      user = generate(user()) |> confirm_user()
      setup_subscription_for_user(user)
      conversation = generate(conversation(actor: user, selected_model_id: model.id))

      stub(LLMMock, :stream_text, fn _model, _context, _opts ->
        MockResponses.stream_text_response("ok")
      end)

      conn
      |> authenticate(user)
      |> visit(~p"/chat/#{conversation.id}")
      |> assert_has("body .phx-connected")
      |> assert_has("button[phx-value-mode='search']")
      |> assert_has("button[phx-value-mode='image_generation']")
      |> assert_has("button[phx-value-mode='video_generation']")
    end

    test "switch to search mode", %{conn: conn} do
      model =
        generate(
          model(
            name: "Search Model",
            key: "test/search-model",
            active?: true,
            supports_search?: true
          )
        )

      user = generate(user()) |> confirm_user()
      setup_subscription_for_user(user)
      conversation = generate(conversation(actor: user, selected_model_id: model.id))

      stub(LLMMock, :stream_text, fn _model, _context, _opts ->
        MockResponses.stream_text_response("ok")
      end)

      conn
      |> authenticate(user)
      |> visit(~p"/chat/#{conversation.id}")
      |> assert_has("body .phx-connected")
      |> assert_has("button[phx-value-mode='search'].btn-ghost")
      |> click("button[phx-value-mode='search']")
      |> assert_has("button[phx-value-mode='search'].btn-primary")
    end
  end
end
