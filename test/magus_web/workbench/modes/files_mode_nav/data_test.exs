defmodule MagusWeb.Workbench.Modes.FilesModeNav.DataTest do
  use Magus.ResourceCase, async: true

  alias MagusWeb.Workbench.Modes.FilesModeNav.Data

  describe "load/1" do
    test "personal mode returns entry points without 'shared'" do
      user = generate(user())

      %{entry_points: items} =
        Data.load(%{
          user: user,
          workspace_id: nil,
          expanded_collection_ids: MapSet.new()
        })

      keys = Enum.map(items, & &1.key)
      assert :my_files in keys
      refute :shared in keys
      assert :recent in keys
      assert :templates in keys
      assert :knowledge in keys
      assert :trash in keys
    end

    test "workspace mode includes 'shared'" do
      user = generate(user())
      ws = generate(workspace(actor: user))

      %{entry_points: items} =
        Data.load(%{
          user: user,
          workspace_id: ws.id,
          expanded_collection_ids: MapSet.new()
        })

      assert :shared in Enum.map(items, & &1.key)
    end

    test "expanded knowledge group loads collections" do
      user = generate(user())

      %{collections: collections} =
        Data.load(%{
          user: user,
          workspace_id: nil,
          expanded_collection_ids: MapSet.new([:knowledge])
        })

      assert is_list(collections)
    end

    test "collapsed knowledge group returns empty collections list" do
      user = generate(user())

      %{collections: collections} =
        Data.load(%{
          user: user,
          workspace_id: nil,
          expanded_collection_ids: MapSet.new()
        })

      assert collections == []
    end
  end
end
