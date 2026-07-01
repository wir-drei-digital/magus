defmodule Magus.Models.BaseUrlValidatorTest do
  use ExUnit.Case, async: true
  alias Magus.Models.BaseUrlValidator

  test "accepts a public https url" do
    # Offline-deterministic: a dotted-quad literal is resolved locally by
    # :inet.getaddr without a network DNS lookup. 8.8.8.8 is a public IP that
    # is not in any blocked range, so this positive case never depends on live
    # DNS.
    assert :ok = BaseUrlValidator.validate("https://8.8.8.8/v1")
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

  test "rejects IPv4-mapped IPv6 pointing at a blocked range" do
    # Regression: these previously returned :ok because the hand-rolled
    # blocklist did not decode ::ffff:x IPv4-mapped IPv6 addresses.
    assert {:error, _} = BaseUrlValidator.validate("https://[::ffff:169.254.169.254]/v1")
    assert {:error, _} = BaseUrlValidator.validate("https://[::ffff:127.0.0.1]/v1")
  end

  test "rejects IPv6 link-local" do
    # Regression: fe80::/10 link-local was not covered by the old blocklist.
    assert {:error, _} = BaseUrlValidator.validate("https://[fe80::1]/v1")
  end

  test "rejects embedded credentials" do
    assert {:error, _} = BaseUrlValidator.validate("https://user:pass@api.example.com/v1")
  end

  test "rejects garbage" do
    assert {:error, _} = BaseUrlValidator.validate("not a url")
    assert {:error, _} = BaseUrlValidator.validate("")
  end
end
