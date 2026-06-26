defmodule Magus.Knowledge.Connectors.AffineTest do
  use ExUnit.Case, async: true

  alias Magus.Knowledge.Connectors.Affine

  describe "connect/1" do
    test "creates connection with API key" do
      assert {:ok, conn} = Affine.connect(%{"api_key" => "af_test"})
      assert conn.api_key == "af_test"
      assert conn.base_url == "https://app.affine.pro"
    end

    test "creates connection with custom base URL" do
      config = %{"api_key" => "af_test", "base_url" => "https://affine.local"}
      assert {:ok, conn} = Affine.connect(config)
      assert conn.base_url == "https://affine.local"
    end

    test "strips trailing slash from base_url" do
      config = %{"api_key" => "af_test", "base_url" => "https://affine.local/"}
      assert {:ok, conn} = Affine.connect(config)
      assert conn.base_url == "https://affine.local"
    end

    test "fails without API key" do
      assert {:error, :missing_api_key} = Affine.connect(%{})
    end

    test "fails with empty API key" do
      assert {:error, :missing_api_key} = Affine.connect(%{"api_key" => ""})
    end

    test "stub callbacks return not_supported" do
      {:ok, conn} = Affine.connect(%{"api_key" => "af_test"})

      assert {:error, :not_supported} = Affine.list_folders(conn, nil)
      assert {:error, :not_supported} = Affine.list_items(conn, %{}, nil)
      assert {:error, :not_supported} = Affine.fetch_content(conn, %{})
      assert {:error, :not_supported} = Affine.detect_changes(conn, %{}, DateTime.utc_now())
    end
  end
end
