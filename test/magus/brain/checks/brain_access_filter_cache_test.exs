defmodule Magus.Brain.Checks.BrainAccessFilterCacheTest do
  @moduledoc """
  Unit tests for the request-scoped memoization in
  `Magus.Brain.Checks.BrainAccessFilter`.

  These guard the security-critical invariant: the cache must only be active
  inside an explicit `with_request_cache/1` scope, and must be torn down in
  the `after` block so it never outlives a single synchronous load pass. A
  stale cache on an authorization filter would let a revoked grant linger.
  """
  use Magus.DataCase, async: false

  import Magus.Generators

  alias Magus.Brain
  alias Magus.Brain.Checks.BrainAccessFilter

  describe "with_request_cache/1 scoping" do
    test "no scope key is left in the process dictionary after the scope ends" do
      user = generate(user())

      BrainAccessFilter.with_request_cache(fn ->
        assert Process.get(:brain_access_scope_active) == true
        # Trigger a real resolution so a cache entry would be written if active.
        {:ok, _} = Brain.list_brains(actor: user)
        :ok
      end)

      refute Process.get(:brain_access_scope_active)

      cache_keys =
        Process.get_keys()
        |> Enum.filter(&match?({:brain_access_ids, _, _, _}, &1))

      assert cache_keys == [],
             "request-scoped access cache leaked past the scope: #{inspect(cache_keys)}"
    end

    test "the scope is torn down even when the wrapped fun raises" do
      assert_raise RuntimeError, fn ->
        BrainAccessFilter.with_request_cache(fn -> raise "boom" end)
      end

      refute Process.get(:brain_access_scope_active)

      cache_keys =
        Process.get_keys()
        |> Enum.filter(&match?({:brain_access_ids, _, _, _}, &1))

      assert cache_keys == []
    end

    test "nested scopes do not clear the outer cache early" do
      user = generate(user())

      BrainAccessFilter.with_request_cache(fn ->
        {:ok, _} = Brain.list_brains(actor: user)
        # Inner scope is a no-op for ownership/teardown: it must NOT clear
        # the outer scope's flag or cache when it returns.
        BrainAccessFilter.with_request_cache(fn -> :ok end)

        assert Process.get(:brain_access_scope_active) == true
        :ok
      end)

      refute Process.get(:brain_access_scope_active)
    end
  end

  describe "authorization correctness through the scoped filter" do
    test "owner sees their brain inside the scope" do
      user = generate(user())
      {:ok, brain} = Brain.create_brain(%{title: "Mine"}, actor: user)

      result =
        BrainAccessFilter.with_request_cache(fn ->
          Brain.get_brain(brain.id, actor: user)
        end)

      assert {:ok, found} = result
      assert found.id == brain.id
    end

    test "a user is still DENIED a brain they cannot access, even inside the scope" do
      owner = generate(user())
      other = generate(user())
      {:ok, brain} = Brain.create_brain(%{title: "Secret"}, actor: owner)
      {:ok, page} = Brain.create_page(brain.id, %{title: "Hidden page"}, actor: owner)

      # Brain-level read denial.
      brain_result =
        BrainAccessFilter.with_request_cache(fn ->
          Brain.get_brain(brain.id, actor: other)
        end)

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} = brain_result

      # Page-level read denial (the filter path BrainPageView depends on).
      page_result =
        BrainAccessFilter.with_request_cache(fn ->
          Brain.get_page(page.id, actor: other)
        end)

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} = page_result

      # And listing pages for that brain yields nothing for the other user.
      pages_result =
        BrainAccessFilter.with_request_cache(fn ->
          Brain.list_pages(brain.id, actor: other)
        end)

      assert {:ok, []} = pages_result
    end

    test "denial holds the same way without an active scope (no behavior change)" do
      owner = generate(user())
      other = generate(user())
      {:ok, brain} = Brain.create_brain(%{title: "Secret"}, actor: owner)

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               Brain.get_brain(brain.id, actor: other)
    end
  end
end
