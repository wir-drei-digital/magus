defmodule Magus.Knowledge.Connectors.GoogleDriveTest do
  use ExUnit.Case, async: true

  alias Magus.Knowledge.Connectors.GoogleDrive

  describe "connect/1" do
    test "creates connection with access token" do
      assert {:ok, conn} = GoogleDrive.connect(%{"access_token" => "ya29.test"})
      assert conn.access_token == "ya29.test"
      assert conn.refresh_token == nil
    end

    test "creates connection with access and refresh tokens" do
      config = %{"access_token" => "ya29.test", "refresh_token" => "1//refresh"}
      assert {:ok, conn} = GoogleDrive.connect(config)
      assert conn.access_token == "ya29.test"
      assert conn.refresh_token == "1//refresh"
    end

    test "fails without access token" do
      assert {:error, :missing_access_token} = GoogleDrive.connect(%{})
    end

    test "fails with empty access token" do
      assert {:error, :missing_access_token} = GoogleDrive.connect(%{"access_token" => ""})
    end
  end
end
