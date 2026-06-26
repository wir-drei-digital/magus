defmodule MagusWeb.Workbench.Resources.Companions.SpreadsheetCompanionTest do
  @moduledoc """
  Tests the SpreadsheetCompanion LiveView's mount, save, and PubSub
  refresh behavior. Does not assert on Univer-specific JS state; the
  LiveView's contract is just to push base64 binary down on load and
  accept base64 binary up on save.
  """
  use MagusWeb.LiveViewCase, async: false

  import Magus.Generators

  alias MagusWeb.Workbench.Resources.Companions.SpreadsheetCompanion
  alias Phoenix.PubSub

  @ai_agent %Magus.Agents.Support.AiAgent{}

  setup ctx do
    user = generate(user())

    binary =
      File.read!(
        Path.join(
          __DIR__,
          "../../../../support/fixtures/sample.xlsx"
        )
      )

    {:ok, file} =
      Magus.Files.create_file_from_content(
        %{
          name: "report.xlsx",
          type: :document,
          mime_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
          user_id: user.id,
          content: binary
        },
        actor: @ai_agent
      )

    Map.merge(ctx, %{user: user, test_file: file})
  end

  test "mounts and pushes a load event with the file binary",
       %{user: user, test_file: file} do
    {:ok, view, _html} =
      Phoenix.LiveViewTest.live_isolated(
        Phoenix.ConnTest.build_conn(),
        SpreadsheetCompanion,
        session: %{
          "file_id" => file.id,
          "user_id" => user.id,
          "tab_id" => "tab-1"
        }
      )

    assert_push_event(view, "spreadsheet:load", %{binary: b64})
    assert is_binary(b64)
    assert b64 != ""
  end

  test "save event replaces the binary",
       %{user: user, test_file: file} do
    {:ok, view, _html} =
      Phoenix.LiveViewTest.live_isolated(
        Phoenix.ConnTest.build_conn(),
        SpreadsheetCompanion,
        session: %{
          "file_id" => file.id,
          "user_id" => user.id,
          "tab_id" => "tab-1"
        }
      )

    new_b64 = Base.encode64(String.duplicate("y", 1024))
    Phoenix.LiveViewTest.render_hook(view, "spreadsheet:save", %{"binary" => new_b64})

    reloaded = Magus.Files.get_file!(file.id, actor: user)
    assert reloaded.file_size == 1024
  end

  test "PubSub agent update triggers another spreadsheet:load",
       %{user: user, test_file: file} do
    {:ok, view, _html} =
      Phoenix.LiveViewTest.live_isolated(
        Phoenix.ConnTest.build_conn(),
        SpreadsheetCompanion,
        session: %{
          "file_id" => file.id,
          "user_id" => user.id,
          "tab_id" => "tab-1"
        }
      )

    # The first load fires synchronously during mount.
    assert_push_event(view, "spreadsheet:load", _payload)

    PubSub.broadcast(
      Magus.PubSub,
      "files:#{file.id}",
      {:file_updated, file.id, :agent, "external-req"}
    )

    assert_push_event(view, "spreadsheet:load", _payload2)
    assert_push_event(view, "spreadsheet:updated_by_agent", _payload3)
  end

  test "ignores PubSub events that match our own last save",
       %{user: user, test_file: file} do
    {:ok, view, _html} =
      Phoenix.LiveViewTest.live_isolated(
        Phoenix.ConnTest.build_conn(),
        SpreadsheetCompanion,
        session: %{
          "file_id" => file.id,
          "user_id" => user.id,
          "tab_id" => "tab-1"
        }
      )

    assert_push_event(view, "spreadsheet:load", _payload)

    new_b64 = Base.encode64(String.duplicate("z", 256))
    Phoenix.LiveViewTest.render_hook(view, "spreadsheet:save", %{"binary" => new_b64})

    # The save broadcasts {:file_updated, ..., :user, request_id}; the
    # companion should NOT push another spreadsheet:load for its own
    # save (would discard the user's in-flight edits).
    refute_push_event(view, "spreadsheet:load", _, 200)
  end
end
