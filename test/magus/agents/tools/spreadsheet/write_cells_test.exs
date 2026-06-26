defmodule Magus.Agents.Tools.Spreadsheet.WriteCellsTest do
  @moduledoc """
  Live sandbox tests for `Magus.Agents.Tools.Spreadsheet.WriteCells`.

  Tagged `:sandbox` so the default `mix test` run skips them. Run via
  `bin/test-e2e-live --include sandbox` (or `mix test --include sandbox`)
  with `SANDBOX_PROVIDER` plus the active provider's credentials in the
  environment.
  """

  use Magus.ResourceCase, async: false

  import Magus.Generators

  alias Magus.Agents.Tools.Spreadsheet.{ReadSheet, WriteCells}

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

  test "writes cells and broadcasts file_updated", %{
    user: user,
    conv: conv,
    test_file: file
  } do
    Phoenix.PubSub.subscribe(Magus.PubSub, "files:#{file.id}")

    {:ok, %{written: 2}} =
      WriteCells.run(
        %{
          "file_id" => file.id,
          "changes" => [
            %{"sheet" => "Sheet1", "ref" => "A1", "value" => "Q3"},
            %{"sheet" => "Sheet1", "ref" => "B1", "value" => 5_000}
          ]
        },
        %{user_id: user.id, conversation_id: conv.id}
      )

    assert_receive {:file_updated, _id, :agent, _request_id}, 5_000

    {:ok, %{sheets: [sheet]}} =
      ReadSheet.run(%{"file_id" => file.id}, %{user_id: user.id, conversation_id: conv.id})

    assert Enum.find(sheet.cells, &(&1.ref == "A1")).value == "Q3"
    assert Enum.find(sheet.cells, &(&1.ref == "B1")).value == 5_000
  end
end
