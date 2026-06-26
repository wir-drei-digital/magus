defmodule MagusWeb.Workbench.Resources.Companions.PdfCompanionTest do
  use MagusWeb.LiveViewCase, async: false
  import Magus.Generators

  alias MagusWeb.Workbench.Resources.Companions.PdfCompanion

  @fake_file_id "01944444-0000-7000-a000-000000000001"
  @fake_filename "sample.pdf"
  @fake_url "/uploads/files/user/sample.pdf"

  test "mounts with pdf data and renders viewer" do
    user = generate(user())
    ensure_workspace_plan(user)
    ws = generate(workspace(actor: user))

    {:ok, conv} =
      Magus.Chat.create_conversation(%{title: "PDF test", workspace_id: ws.id}, actor: user)

    {:ok, _lv, html} =
      Phoenix.LiveViewTest.live_isolated(
        Phoenix.ConnTest.build_conn(),
        PdfCompanion,
        session: %{
          "file_id" => @fake_file_id,
          "filename" => @fake_filename,
          "url" => @fake_url,
          "conversation_id" => conv.id,
          "user_id" => user.id,
          "tab_id" => "tab_pdf_test"
        }
      )

    assert html =~ @fake_file_id or html =~ @fake_filename or html =~ "pdf"
  end
end
