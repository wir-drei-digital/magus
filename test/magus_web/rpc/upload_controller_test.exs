defmodule MagusWeb.Rpc.UploadControllerTest do
  use MagusWeb.ConnCase, async: true

  import Magus.Generators
  import MagusWeb.LiveViewCase, only: [log_in_user: 2]

  defp upload_fixture(content, filename, content_type) do
    path = Path.join(System.tmp_dir!(), "upload-#{System.unique_integer([:positive])}")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    %Plug.Upload{path: path, filename: filename, content_type: content_type}
  end

  # CheckStorageLimits needs an active subscription; without one the
  # effective max upload size is 0 bytes.
  defp subscribed_user do
    user = generate(user())
    free_plan = ensure_free_plan()

    {:ok, _subscription} =
      Magus.Usage.create_user_subscription(
        %{user_id: user.id, usage_plan_id: free_plan.id, status: :active},
        authorize?: false
      )

    user
  end

  test "uploads a file and returns the RPC envelope", %{conn: conn} do
    user = subscribed_user()
    upload = upload_fixture("hello world", "notes.txt", "text/plain")

    response =
      conn
      |> log_in_user(user)
      |> post("/rpc/upload", %{"file" => upload})
      |> json_response(200)

    assert %{"success" => true, "data" => data} = response
    assert data["name"] == "notes.txt"
    assert data["fileSize"] == byte_size("hello world")
    assert data["id"]

    assert {:ok, file} = Magus.Files.get_file(data["id"], actor: user)
    assert file.name == "notes.txt"
  end

  test "attaches the conversation when conversation_id is given", %{conn: conn} do
    user = subscribed_user()
    conversation = generate(conversation(actor: user))
    upload = upload_fixture("attached", "a.txt", "text/plain")

    response =
      conn
      |> log_in_user(user)
      |> post("/rpc/upload", %{"file" => upload, "conversation_id" => conversation.id})
      |> json_response(200)

    assert %{"success" => true, "data" => %{"id" => id}} = response
    assert {:ok, file} = Magus.Files.get_file(id, actor: user)
    assert file.conversation_id == conversation.id
  end

  test "places the upload in a folder when folder_id is given", %{conn: conn} do
    user = subscribed_user()
    folder = generate(folder(actor: user, kind: :files))
    upload = upload_fixture("in folder", "f.txt", "text/plain")

    response =
      conn
      |> log_in_user(user)
      |> post("/rpc/upload", %{"file" => upload, "folder_id" => folder.id})
      |> json_response(200)

    assert %{"success" => true, "data" => %{"id" => id}} = response
    assert {:ok, file} = Magus.Files.get_file(id, actor: user)
    assert file.folder_id == folder.id
  end

  test "requires authentication", %{conn: conn} do
    upload = upload_fixture("nope", "n.txt", "text/plain")

    conn = post(conn, "/rpc/upload", %{"file" => upload})
    assert json_response(conn, 401)
  end

  test "rejects requests without a file field", %{conn: conn} do
    user = generate(user())

    response =
      conn
      |> log_in_user(user)
      |> post("/rpc/upload", %{})
      |> json_response(400)

    assert %{"success" => false, "errors" => [%{"type" => "upload_failed"}]} = response
  end
end
