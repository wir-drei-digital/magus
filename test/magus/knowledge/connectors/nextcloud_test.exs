defmodule Magus.Knowledge.Connectors.NextcloudTest do
  use ExUnit.Case, async: true

  alias Magus.Knowledge.Connectors.Nextcloud

  describe "connect/1" do
    test "creates connection with valid credentials" do
      config = %{
        "base_url" => "https://cloud.example.com",
        "username" => "user",
        "password" => "pass"
      }

      assert {:ok, conn} = Nextcloud.connect(config)
      assert conn.base_url == "https://cloud.example.com"
      assert conn.username == "user"
      assert conn.password == "pass"
    end

    test "strips trailing slash from base_url" do
      config = %{
        "base_url" => "https://cloud.example.com/",
        "username" => "user",
        "password" => "pass"
      }

      assert {:ok, conn} = Nextcloud.connect(config)
      assert conn.base_url == "https://cloud.example.com"
    end

    test "fails without credentials" do
      assert {:error, :missing_credentials} = Nextcloud.connect(%{})
    end

    test "fails with empty base_url" do
      config = %{"base_url" => "", "username" => "user", "password" => "pass"}
      assert {:error, :missing_credentials} = Nextcloud.connect(config)
    end

    test "fails with empty username" do
      config = %{
        "base_url" => "https://cloud.example.com",
        "username" => "",
        "password" => "pass"
      }

      assert {:error, :missing_credentials} = Nextcloud.connect(config)
    end

    test "fails with empty password" do
      config = %{
        "base_url" => "https://cloud.example.com",
        "username" => "user",
        "password" => ""
      }

      assert {:error, :missing_credentials} = Nextcloud.connect(config)
    end
  end
end
