defmodule Magus.Agents.Tools.Sandbox.FileUploadTest do
  use Magus.DataCase, async: true

  alias Magus.Agents.Tools.Sandbox.FileUpload

  describe "run/2 param validation" do
    test "returns error when neither file_id nor url provided" do
      params = %{"path" => "/workspace/test.txt"}
      context = %{conversation_id: Ecto.UUID.generate(), user_id: Ecto.UUID.generate()}

      assert {:ok, %{error: error}} = FileUpload.run(params, context)
      assert error =~ "file_id"
      assert error =~ "url"
    end

    test "returns error when both file_id and url provided" do
      params = %{
        "file_id" => Ecto.UUID.generate(),
        "url" => "https://example.com/file.csv",
        "path" => "/workspace/test.csv"
      }

      context = %{conversation_id: Ecto.UUID.generate(), user_id: Ecto.UUID.generate()}

      assert {:ok, %{error: error}} = FileUpload.run(params, context)
      assert error =~ "not both"
    end

    test "returns error when context is missing required fields" do
      params = %{"file_id" => Ecto.UUID.generate()}
      context = %{}

      assert {:ok, %{error: error}} = FileUpload.run(params, context)
      assert error =~ "Missing required context"
    end
  end

  describe "display_name/0 and summarize_output/1" do
    test "display_name returns expected string" do
      assert FileUpload.display_name() == "Uploading file..."
    end

    test "summarize_output handles success" do
      assert FileUpload.summarize_output(%{filename: "test.csv", size_bytes: 1024}) ==
               "Uploaded test.csv (1.0 KB)"
    end

    test "summarize_output handles error" do
      assert FileUpload.summarize_output(%{error: "not found"}) == "Error"
    end

    test "summarize_output handles unknown" do
      assert FileUpload.summarize_output(%{}) == "Completed"
    end
  end
end
