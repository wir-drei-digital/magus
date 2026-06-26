defmodule Magus.Brain.PageHistoryTest do
  use Magus.DataCase, async: false
  import Magus.Generators

  alias Magus.Brain

  setup do
    user = generate(user())
    {:ok, brain} = Brain.create_brain(%{title: "Brain"}, actor: user)
    {:ok, page} = Brain.create_page(brain.id, %{title: "Page"}, actor: user)

    {:ok, p1} =
      Brain.update_page_body(
        page,
        %{body: "first body", base_version: page.lock_version},
        actor: user
      )

    {:ok, _p2} =
      Brain.update_page_body(
        p1,
        %{body: "second body", base_version: p1.lock_version},
        actor: user
      )

    %{user: user, brain: brain, page: page}
  end

  test "list_page_versions returns this page's versions newest first", %{page: page} do
    versions = Brain.list_page_versions(page.id)

    assert length(versions) >= 2
    timestamps = Enum.map(versions, & &1.inserted_at)
    assert timestamps == Enum.sort(timestamps, {:desc, DateTime})
    assert Enum.all?(versions, &Map.has_key?(&1, :version_id))
  end

  test "page_version_diff on the latest version flags is_latest? and diffs against the prior body",
       %{page: page} do
    [latest | _] = Brain.list_page_versions(page.id)

    assert {:ok, diff} = Brain.page_version_diff(page.id, latest.version_id)
    assert diff.is_latest?
    assert Enum.any?(diff.diff_rows, &(&1.kind == :ins))
  end

  test "page_version_diff returns :error for an unknown version id", %{page: page} do
    assert :error == Brain.page_version_diff(page.id, Ecto.UUID.generate())
  end

  test "page_version_body returns the snapshot body for a version", %{page: page} do
    [latest | _] = Brain.list_page_versions(page.id)
    assert {:ok, body} = Brain.page_version_body(page.id, latest.version_id)
    assert is_binary(body)
  end
end
