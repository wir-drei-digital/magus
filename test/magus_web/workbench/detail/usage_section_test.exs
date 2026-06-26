defmodule MagusWeb.Workbench.Detail.UsageSectionTest do
  use MagusWeb.LiveViewCase, async: false

  import Phoenix.LiveViewTest
  import MagusWeb.LiveViewCase
  import Magus.Generators

  describe "GET /settings/usage" do
    test "renders the usage section", %{conn: conn} do
      user = generate(user())
      conn = log_in_user(conn, user)
      {:ok, _view, html} = live(conn, ~p"/settings/usage")
      assert html =~ ~s(data-settings-section="usage")
      assert html =~ ~s(data-testid="summary-token-total")
    end

    test "summary token total is humanized with K/M abbreviations", %{conn: conn} do
      user = generate(user())
      conn = log_in_user(conn, user)

      model = generate(model())
      conv = generate(conversation(actor: user))

      create_usage_record(user, model,
        conversation_id: conv.id,
        billable: true,
        total_tokens: 2_500_000
      )

      {:ok, _view, html} = live(conn, ~p"/settings/usage")

      # 2_500_000 -> "2.5M" in the token summary card; "M" can't appear in a UUID.
      assert html =~ "2.5M"
    end

    test "summary reflects only billable rows and the table links to messages", %{conn: conn} do
      user = generate(user())
      conn = log_in_user(conn, user)

      billable_model = generate(model(name: "BillableModel"))
      hidden_model = generate(model(name: "HiddenModel"))
      conv = generate(conversation(actor: user))
      msg = generate(message(actor: user, conversation_id: conv.id, text: "hi"))

      create_usage_record(user, billable_model,
        conversation_id: conv.id,
        message_id: msg.id,
        billable: true,
        total_tokens: 200,
        total_cost: Decimal.new("0.10")
      )

      create_usage_record(user, hidden_model,
        conversation_id: conv.id,
        billable: false,
        total_tokens: 999
      )

      {:ok, _view, html} = live(conn, ~p"/settings/usage")

      # Billable row is shown; the non-billable row is excluded. Assert on model
      # names rather than bare token counts, which can collide with hex chars in
      # the streamed rows' v7-UUID DOM ids.
      assert html =~ "BillableModel"
      refute html =~ "HiddenModel"
      # row links to the message in its conversation
      assert html =~ ~s(href="/chat/#{conv.id}?highlight=#{msg.id}")
    end

    test "applying a model filter narrows summary and table reactively", %{conn: conn} do
      user = generate(user())
      conn = log_in_user(conn, user)

      keep = generate(model(name: "Keep"))
      drop = generate(model(name: "Drop"))
      conv = generate(conversation(actor: user))

      create_usage_record(user, keep, conversation_id: conv.id, billable: true, total_tokens: 10)
      create_usage_record(user, drop, conversation_id: conv.id, billable: true, total_tokens: 99)

      {:ok, view, _html} = live(conn, ~p"/settings/usage")
      # SettingsView is a child LiveView (live_render); drive events on the child.
      section = find_live_child(view, "detail-settings-usage")

      section
      |> form("#usage-filters",
        filters: %{model_name: "Keep", range: "current_period", workspace: "all"}
      )
      |> render_change()

      # Scope the model-name assertions to the streamed table body: "Drop"
      # lingers as a <select> option in the full page, so check the rows only.
      rows = section |> element("#usage-rows") |> render()
      assert rows =~ ~s(data-testid="usage-row")
      assert rows =~ "Keep"
      refute rows =~ "Drop"
    end

    test "page event moves to the next page", %{conn: conn} do
      user = generate(user())
      conn = log_in_user(conn, user)

      model = generate(model())
      conv = generate(conversation(actor: user))

      for _ <- 1..30,
          do: create_usage_record(user, model, conversation_id: conv.id, billable: true)

      {:ok, view, _html} = live(conn, ~p"/settings/usage")
      # SettingsView is a child LiveView (live_render); drive events on the child.
      section = find_live_child(view, "detail-settings-usage")
      section |> element(~s([data-testid="page-next"])) |> render_click()

      # Verify the page actually advanced. Scope to the indicator element so the
      # "2 /" check can't collide with hex chars in a streamed row's UUID id.
      indicator = section |> element(~s([data-testid="page-indicator"])) |> render()
      assert indicator =~ "2 /"
    end
  end
end
