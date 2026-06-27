defmodule Magus.Skills.DiscoveryTest do
  use Magus.ResourceCase, async: true

  alias Magus.Skills
  alias Magus.Skills.Discovery

  test "includes built-in skills with builtin: refs even for a nil actor" do
    views = Discovery.list_for_actor(nil)
    assert Enum.all?(views, &(&1.source == :builtin))
    assert Enum.all?(views, &String.starts_with?(&1.ref, "builtin:"))
    # The repo ships built-in skills under priv/skills, so the list is non-empty.
    assert views != []
  end

  test "includes the actor's own user skills with user: refs, isolated per actor" do
    owner = generate(user())
    stranger = generate(user())
    {:ok, skill} = Skills.create_skill(%{name: "mine-disc", description: "d"}, actor: owner)

    owner_refs = Discovery.list_for_actor(owner) |> Enum.map(& &1.ref)
    assert ("user:" <> skill.id) in owner_refs

    stranger_refs = Discovery.list_for_actor(stranger) |> Enum.map(& &1.ref)
    refute ("user:" <> skill.id) in stranger_refs
  end

  test "refs are unique across the merged list" do
    owner = generate(user())
    {:ok, _} = Skills.create_skill(%{name: "uniq-disc", description: "d"}, actor: owner)
    refs = Discovery.list_for_actor(owner) |> Enum.map(& &1.ref)
    assert length(refs) == length(Enum.uniq(refs))
  end
end
