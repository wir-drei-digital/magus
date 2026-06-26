defmodule Magus.Agents.Tools.Spreadsheet.ReadSheetTest do
  @moduledoc """
  Live sandbox tests for `Magus.Agents.Tools.Spreadsheet.ReadSheet`.

  Tagged `:sandbox` so they are excluded from the default test run. They
  require `SANDBOX_PROVIDER` plus the active sandbox provider's
  credentials in the environment. The local-only `mix test` run skips
  them; the module is still required to compile cleanly so
  `mix precommit` does not regress.
  """

  use Magus.ResourceCase, async: false

  import Magus.Generators

  alias Magus.Agents.Tools.Spreadsheet.ReadSheet

  @moduletag :sandbox

  @fixture_path Path.expand("../../../../support/fixtures/sample.xlsx", __DIR__)

  setup do
    user = generate(user())
    conv = generate(conversation(actor: user))
    xlsx = File.read!(@fixture_path)

    {:ok, file} =
      Magus.Files.create_file_from_content(
        %{
          name: "report.xlsx",
          type: :document,
          mime_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
          user_id: user.id,
          content: xlsx
        },
        actor: %Magus.Agents.Support.AiAgent{user_id: user.id}
      )

    %{user: user, conv: conv, test_file: file}
  end

  test "returns sheet data with cell values", %{
    user: user,
    conv: conv,
    test_file: file
  } do
    {:ok, %{sheets: sheets}} =
      ReadSheet.run(
        %{"file_id" => file.id},
        %{user_id: user.id, conversation_id: conv.id}
      )

    assert [%{name: "Sheet1", cells: cells}] = sheets
    assert Enum.find(cells, &(&1.ref == "A1")).value == "Q1"
    assert Enum.find(cells, &(&1.ref == "B1")).value == 1234.5
  end

  test "supports sheet_name and range filters", %{
    user: user,
    conv: conv,
    test_file: file
  } do
    {:ok, %{sheets: [sheet]}} =
      ReadSheet.run(
        %{"file_id" => file.id, "sheet_name" => "Sheet1", "range" => "A1:A1"},
        %{user_id: user.id, conversation_id: conv.id}
      )

    assert sheet.name == "Sheet1"
    assert length(sheet.cells) == 1
    assert hd(sheet.cells).ref == "A1"
  end
end
