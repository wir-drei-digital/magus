defmodule Magus.Agents.Tools.Integrations.SsrfValidatorTest do
  use ExUnit.Case, async: true

  alias Magus.Agents.Tools.Integrations.SsrfValidator

  describe "validate_url/1" do
    test "allows valid public HTTPS URLs" do
      assert :ok = SsrfValidator.validate_url("https://api.github.com/repos")
      assert :ok = SsrfValidator.validate_url("https://mycompany.atlassian.net/rest/api/3/issue")
    end

    test "allows valid public HTTP URLs" do
      # Use a public IP literal to avoid DNS dependency in test environment
      assert :ok = SsrfValidator.validate_url("http://1.1.1.1/data")
    end

    test "rejects file:// scheme" do
      assert {:error, _} = SsrfValidator.validate_url("file:///etc/passwd")
    end

    test "rejects ftp:// scheme" do
      assert {:error, _} = SsrfValidator.validate_url("ftp://internal.server/file")
    end

    test "rejects localhost" do
      assert {:error, _} = SsrfValidator.validate_url("http://localhost/admin")
      assert {:error, _} = SsrfValidator.validate_url("http://localhost:4000/admin")
    end

    test "rejects 127.0.0.0/8 range" do
      assert {:error, _} = SsrfValidator.validate_url("http://127.0.0.1/secret")
      assert {:error, _} = SsrfValidator.validate_url("http://127.0.0.2:8080/")
    end

    test "rejects 10.0.0.0/8 private range" do
      assert {:error, _} = SsrfValidator.validate_url("http://10.0.0.1/internal")
      assert {:error, _} = SsrfValidator.validate_url("http://10.255.255.255/")
    end

    test "rejects 172.16.0.0/12 private range" do
      assert {:error, _} = SsrfValidator.validate_url("http://172.16.0.1/")
      assert {:error, _} = SsrfValidator.validate_url("http://172.31.255.255/")
    end

    test "rejects 192.168.0.0/16 private range" do
      assert {:error, _} = SsrfValidator.validate_url("http://192.168.1.1/")
      assert {:error, _} = SsrfValidator.validate_url("http://192.168.0.100:3000/")
    end

    test "rejects 169.254.0.0/16 link-local range" do
      assert {:error, _} = SsrfValidator.validate_url("http://169.254.169.254/latest/meta-data/")
    end

    test "rejects empty or invalid URLs" do
      assert {:error, _} = SsrfValidator.validate_url("")
      assert {:error, _} = SsrfValidator.validate_url("not-a-url")
    end
  end
end
