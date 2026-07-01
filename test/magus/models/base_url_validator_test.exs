defmodule Magus.Models.BaseUrlValidatorTest do
  use ExUnit.Case, async: true
  alias Magus.Models.BaseUrlValidator

  test "accepts a public https url" do
    # NOTE: deviates from the brief's `api.example.com`, which is a non-existent
    # subdomain of the IANA documentation domain and returns NXDOMAIN. The
    # validator resolves the host at validation time (a deliberate SSRF guard),
    # so the positive case must use a host that actually resolves to a public
    # IP. `example.com` is IANA-reserved for docs and resolves to public IPs.
    assert :ok = BaseUrlValidator.validate("https://example.com/v1")
  end

  test "rejects non-https" do
    assert {:error, _} = BaseUrlValidator.validate("http://api.example.com/v1")
  end

  test "rejects loopback" do
    assert {:error, _} = BaseUrlValidator.validate("https://127.0.0.1/v1")
    assert {:error, _} = BaseUrlValidator.validate("https://localhost/v1")
  end

  test "rejects private ranges" do
    for host <- ["10.0.0.1", "172.16.0.1", "192.168.1.1", "169.254.169.254"] do
      assert {:error, _} = BaseUrlValidator.validate("https://#{host}/v1")
    end
  end

  test "rejects embedded credentials" do
    assert {:error, _} = BaseUrlValidator.validate("https://user:pass@api.example.com/v1")
  end

  test "rejects garbage" do
    assert {:error, _} = BaseUrlValidator.validate("not a url")
    assert {:error, _} = BaseUrlValidator.validate("")
  end
end
