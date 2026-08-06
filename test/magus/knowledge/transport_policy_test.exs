defmodule Magus.Knowledge.TransportPolicyTest do
  # async: false: flips the global :knowledge_transport Application env.
  use ExUnit.Case, async: false

  alias Magus.Knowledge.TransportPolicy

  defp set_policy(allow_insecure) do
    prev = Application.get_env(:magus, :knowledge_transport)
    Application.put_env(:magus, :knowledge_transport, allow_insecure: allow_insecure)
    on_exit(fn -> Application.put_env(:magus, :knowledge_transport, prev) end)
  end

  describe "strict policy (allow_insecure: false)" do
    setup do
      set_policy(false)
      :ok
    end

    test "rejects http endpoints" do
      assert TransportPolicy.validate_base_url("http://nas.example.com/dav") ==
               {:error, :https_required}
    end

    test "rejects https endpoints resolving to loopback/private ranges" do
      assert TransportPolicy.validate_base_url("https://localhost/remote.php/dav") ==
               {:error, :blocked_host}

      assert TransportPolicy.validate_base_url("https://10.0.0.5/dav") ==
               {:error, :blocked_host}

      assert TransportPolicy.validate_base_url("https://169.254.169.254/latest") ==
               {:error, :blocked_host}
    end

    test "accepts https endpoints on public addresses" do
      # IP literal: no DNS dependency in CI.
      assert TransportPolicy.validate_base_url("https://1.1.1.1/dav") == :ok
    end

    test "the WebDAV connector surfaces the policy error from connect/1" do
      assert {:error, :https_required} =
               Magus.Knowledge.Connectors.Webdav.connect(%{
                 "base_url" => "http://nas.example.com/dav",
                 "username" => "u",
                 "password" => "p"
               })
    end

    test "the Nextcloud connector surfaces the policy error from connect/1" do
      assert {:error, :blocked_host} =
               Magus.Knowledge.Connectors.Nextcloud.connect(%{
                 "base_url" => "https://192.168.1.10",
                 "username" => "u",
                 "password" => "p"
               })
    end
  end

  describe "opt-out (allow_insecure: true)" do
    setup do
      set_policy(true)
      :ok
    end

    test "permits http and private hosts (self-hosted LAN NAS)" do
      assert TransportPolicy.validate_base_url("http://192.168.1.10/dav") == :ok
      assert TransportPolicy.validate_base_url("http://localhost:8080") == :ok
    end
  end
end
