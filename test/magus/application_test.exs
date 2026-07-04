defmodule Magus.ApplicationTest do
  @moduledoc """
  Tests for the open-core / `magus_cloud` composition seam in
  `Magus.Application.child_specs/0`.

  The supervision tree must not hardcode `MagusWeb.Endpoint`: it resolves the
  web endpoint through the `Magus.Endpoint` facade (`:magus, :endpoint`) and
  injects a configurable `:magus, :extra_children` list, so `magus_cloud` can
  serve `MagusCloudWeb.Endpoint` and start billing supervisors without the core
  naming either.
  """
  # async: false — these tests mutate the global :magus, :endpoint and
  # :magus, :extra_children app env.
  use ExUnit.Case, async: false

  defmodule FakeEndpoint do
    def config_change(_changed, _removed), do: :ok
  end

  defp restore_env(key) do
    original = Application.fetch_env(:magus, key)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:magus, key, value)
        :error -> Application.delete_env(:magus, key)
      end
    end)
  end

  describe "default composition (pure OSS install)" do
    test "returns a non-empty list anchored by the real core children" do
      specs = Magus.Application.child_specs()

      assert is_list(specs) and specs != []
      assert Magus.Repo in specs
      assert {AshAuthentication.Supervisor, [otp_app: :magus]} in specs
    end

    test "serves MagusWeb.Endpoint by default" do
      assert MagusWeb.Endpoint in Magus.Application.child_specs()
    end

    test "injects no extra children by default" do
      refute :sentinel_child in Magus.Application.child_specs()
    end
  end

  describe "configurable web endpoint" do
    setup do
      restore_env(:endpoint)
      Application.put_env(:magus, :endpoint, FakeEndpoint)
      :ok
    end

    test "serves the configured endpoint instead of MagusWeb.Endpoint" do
      specs = Magus.Application.child_specs()

      assert FakeEndpoint in specs
      refute MagusWeb.Endpoint in specs
    end
  end

  describe "configurable extra children" do
    setup do
      restore_env(:extra_children)
      Application.put_env(:magus, :extra_children, [:sentinel_child])
      :ok
    end

    test "injects the configured extra children" do
      assert :sentinel_child in Magus.Application.child_specs()
    end

    test "starts extra children before the web endpoint begins serving" do
      specs = Magus.Application.child_specs()
      endpoint = Magus.Endpoint.endpoint()

      assert index_of(specs, :sentinel_child) < index_of(specs, endpoint)
    end
  end

  describe "ensure_trigger_queues/2 (Oban queue drift guard)" do
    # The set of queues every AshOban trigger in the real domains needs present,
    # derived the same way AshOban's require_queues! checks them.
    defp required_trigger_queues do
      Application.fetch_env!(:magus, :ash_domains)
      |> Enum.flat_map(&Ash.Domain.Info.resources/1)
      |> Enum.flat_map(&AshOban.Info.oban_triggers_and_scheduled_actions/1)
      |> Enum.flat_map(fn trigger -> [trigger.queue, Map.get(trigger, :scheduler_queue)] end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
    end

    test "registers every trigger queue even when the base config declares none" do
      domains = Application.fetch_env!(:magus, :ash_domains)
      # A base that mirrors nothing — the worst case an edition can drift into.
      base = [queues: [default: 10]]

      merged = Magus.Application.ensure_trigger_queues(base, domains)
      queues = Keyword.fetch!(merged, :queues)

      missing = Enum.reject(required_trigger_queues(), &Keyword.has_key?(queues, &1))
      assert missing == [], "trigger queues absent after derivation: #{inspect(missing)}"
    end

    test "auto-registered queues default to limit 1" do
      domains = Application.fetch_env!(:magus, :ash_domains)
      merged = Magus.Application.ensure_trigger_queues([queues: []], domains)
      queues = Keyword.fetch!(merged, :queues)

      # agent_heartbeat_watchdog is a real trigger queue (the one that took prod
      # down on 2026-07-04); it must be present at the conservative default.
      assert queues[:agent_heartbeat_watchdog] == 1
    end

    test "explicit limits win over the derived default (put_new semantics)" do
      domains = Application.fetch_env!(:magus, :ash_domains)
      base = [queues: [agent_heartbeat_watchdog: 7, default: 10]]

      merged = Magus.Application.ensure_trigger_queues(base, domains)
      queues = Keyword.fetch!(merged, :queues)

      assert queues[:agent_heartbeat_watchdog] == 7
      assert queues[:default] == 10
    end

    test "leaves a queues: false config untouched (queue-less node)" do
      domains = Application.fetch_env!(:magus, :ash_domains)
      assert Magus.Application.ensure_trigger_queues([queues: false], domains) == [queues: false]
    end

    test "the real assembled Oban config satisfies require_queues! for every trigger" do
      # AshOban.config/2 raises if any trigger queue is missing; building it from
      # the real base config proves the running app boots without queue drift.
      domains = Application.fetch_env!(:magus, :ash_domains)
      base = Application.fetch_env!(:magus, Oban)

      config = AshOban.config(domains, Magus.Application.ensure_trigger_queues(base, domains))
      queues = Keyword.fetch!(config, :queues)

      missing = Enum.reject(required_trigger_queues(), &Keyword.has_key?(queues, &1))
      assert missing == []
    end
  end

  defp index_of(list, value), do: Enum.find_index(list, &(&1 == value))
end
