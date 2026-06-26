defmodule Magus.DomainsTest do
  @moduledoc """
  Tests for `Magus.Domains`, the exported core Ash domain list used by the
  open-core / cloud composition seam. `magus_cloud` builds its domain list as
  `Magus.Domains.core_domains() ++ cloud_domains()`.
  """
  use ExUnit.Case, async: true

  describe "core_domains/0" do
    test "returns a non-empty list including the core domains" do
      domains = Magus.Domains.core_domains()
      assert is_list(domains) and domains != []
      assert Magus.Chat in domains
      assert Magus.Brain in domains
      assert Magus.Accounts in domains
      assert Magus.Usage in domains
    end

    test "excludes the cloud-only Magus.Billing domain" do
      refute Magus.Billing in Magus.Domains.core_domains()
    end

    test "every entry is a loaded module" do
      for domain <- Magus.Domains.core_domains() do
        assert is_atom(domain) and Code.ensure_loaded?(domain),
               "#{inspect(domain)} is not a loaded module"
      end
    end

    test "the :ash_domains config is exactly core_domains/0 (no Billing)" do
      domains = Application.fetch_env!(:magus, :ash_domains)
      assert Enum.sort(domains) == Enum.sort(Magus.Domains.core_domains())
      refute Magus.Billing in domains
    end

    test "billing_edition? is false in the open-core edition" do
      refute Magus.Usage.billing_edition?()
    end
  end
end
