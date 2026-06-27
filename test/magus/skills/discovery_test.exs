defmodule Magus.Skills.DiscoveryTest do
  use Magus.ResourceCase, async: true

  alias Magus.Skills
  alias Magus.Skills.Discovery

  test "runnable is false for a user skill with has_executable_bundle when sandbox is not configured" do
    # In the test env, Magus.Sandbox.Provider.configured?() returns false
    # because the :test provider's configured?/0 returns false.
    owner = generate(user())

    {:ok, skill} =
      Skills.import_skill(
        %{
          name: "my-bundle-skill",
          description: "a bundled skill",
          has_executable_bundle: true
        },
        actor: owner
      )

    views = Discovery.list_for_actor(owner)
    view = Enum.find(views, &(&1.ref == "user:" <> skill.id))

    assert view, "expected to find the skill in the discovery list"
    assert view.has_executable_bundle == true

    assert view.runnable == false,
           "bundled skill should be non-runnable when sandbox is not configured"
  end

  test "runnable is true for a user skill without an executable bundle" do
    owner = generate(user())

    {:ok, skill} =
      Skills.create_skill(%{name: "plain-skill", description: "no bundle"}, actor: owner)

    views = Discovery.list_for_actor(owner)
    view = Enum.find(views, &(&1.ref == "user:" <> skill.id))

    assert view, "expected to find the skill in the discovery list"
    assert view.has_executable_bundle == false
    assert view.runnable == true, "non-bundle skill should always be runnable"
  end

  test "runnable is true for all built-in skills" do
    views = Discovery.list_for_actor(nil)

    assert Enum.all?(views, &(&1.runnable == true)),
           "all built-in skills should be runnable"
  end

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
