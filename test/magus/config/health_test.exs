defmodule Magus.Config.HealthTest do
  @moduledoc """
  `Magus.Config.Health` is the self-host configuration diagnostic surfaced by
  `mix magus.doctor` and `bin/magus eval "Magus.Config.Health.print()"`. It
  reports required boot config and optional capabilities as ok / missing /
  not-configured without ever failing the boot itself.
  """
  use ExUnit.Case, async: true

  alias Magus.Config.Health

  describe "classify/2" do
    test "a present value is :ok regardless of required?" do
      assert Health.classify(true, true) == :ok
      assert Health.classify(true, false) == :ok
    end

    test "an absent required value is :missing" do
      assert Health.classify(false, true) == :missing
    end

    test "an absent optional value is :not_configured" do
      assert Health.classify(false, false) == :not_configured
    end
  end

  describe "checks/0" do
    test "returns a non-empty list of checks with the documented shape" do
      checks = Health.checks()
      assert is_list(checks) and checks != []

      for c <- checks do
        assert %{key: key, label: label, category: category, required?: required?, status: status} =
                 c

        assert is_atom(key)
        assert is_binary(label)
        assert is_atom(category)
        assert is_boolean(required?)
        assert status in [:ok, :missing, :not_configured]
      end
    end

    test "reports the core boot secrets as required checks" do
      required_keys = for c <- Health.checks(), c.required?, do: c.key

      assert :database in required_keys
      assert :secret_key_base in required_keys
      assert :token_signing_secret in required_keys
    end

    test "reports the optional capabilities" do
      keys = for c <- Health.checks(), do: c.key

      assert :llm_provider in keys
      assert :search in keys
      assert :sandbox in keys
      assert :mail in keys
    end
  end

  describe "all_required_ok?/0" do
    test "is true exactly when no required check is missing" do
      checks = Health.checks()
      expected = Enum.all?(checks, fn c -> not c.required? or c.status == :ok end)

      assert Health.all_required_ok?() == expected
    end
  end

  describe "report/0" do
    test "renders a string including the header and a known check label" do
      report = Health.report()

      assert is_binary(report)
      assert report =~ "Magus configuration health"
      assert report =~ "Database (Postgres)"
    end
  end
end
