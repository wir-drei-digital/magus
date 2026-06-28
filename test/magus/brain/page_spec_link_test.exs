defmodule Magus.Brain.PageSpecLinkTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  alias Magus.Brain

  setup do
    user = generate(user())
    {:ok, brain} = Brain.create_brain(%{title: "Test Brain"}, actor: user)
    %{user: user, brain: brain}
  end

  describe ":spec kind" do
    test "set_kind accepts :spec", %{user: user, brain: brain} do
      {:ok, page} = Brain.create_page(brain.id, %{title: "Auth Spec"}, actor: user)

      assert {:ok, spec} = Brain.set_page_kind(page, :spec, actor: user)
      assert spec.kind == :spec
    end
  end

  describe "spec <-> plan link" do
    test "a plan loads its spec_page", %{user: user, brain: brain} do
      {:ok, spec} = Brain.create_page(brain.id, %{title: "Auth Spec", kind: :spec}, actor: user)
      {:ok, plan} = Brain.create_page(brain.id, %{title: "Auth Plan", kind: :plan}, actor: user)

      assert {:ok, linked} = Brain.set_page_spec(plan, spec.id, actor: user)
      assert linked.spec_page_id == spec.id

      loaded = Ash.load!(linked, :spec_page, actor: user)
      assert loaded.spec_page.id == spec.id
      assert loaded.spec_page.kind == :spec
    end

    test "the spec lists its implementing plans via :plans_for_spec", %{user: user, brain: brain} do
      {:ok, spec} = Brain.create_page(brain.id, %{title: "Auth Spec", kind: :spec}, actor: user)
      {:ok, plan} = Brain.create_page(brain.id, %{title: "Auth Plan", kind: :plan}, actor: user)
      {:ok, _linked} = Brain.set_page_spec(plan, spec.id, actor: user)

      assert {:ok, plans} = Brain.plans_for_spec(spec.id, actor: user)
      assert Enum.map(plans, & &1.id) == [plan.id]
    end

    test "spec_page_id is nullable (a plan with no spec)", %{user: user, brain: brain} do
      {:ok, plan} =
        Brain.create_page(brain.id, %{title: "Standalone Plan", kind: :plan}, actor: user)

      assert plan.spec_page_id == nil
    end
  end
end
