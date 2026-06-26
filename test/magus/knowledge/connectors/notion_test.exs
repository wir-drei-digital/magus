defmodule Magus.Knowledge.Connectors.NotionTest do
  use ExUnit.Case, async: true

  alias Magus.Knowledge.Connectors.Notion

  describe "connect/1" do
    test "creates connection with API key" do
      assert {:ok, conn} = Notion.connect(%{"api_key" => "test_key"})
      assert conn.token == "test_key"
    end

    test "creates connection with OAuth access token" do
      assert {:ok, conn} = Notion.connect(%{"access_token" => "ntn_test"})
      assert conn.token == "ntn_test"
    end

    test "fails without API key" do
      assert {:error, _} = Notion.connect(%{})
    end

    test "fails with empty API key" do
      assert {:error, _} = Notion.connect(%{"api_key" => ""})
    end
  end
end
