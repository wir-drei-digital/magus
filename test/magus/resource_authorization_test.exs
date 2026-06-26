defmodule Magus.ResourceAuthorizationTest do
  use Magus.ResourceCase, async: true

  alias Magus.{Chat, Files, Library}

  defp create_file(user, attrs) do
    defaults = %{
      name: "auth-test-file.txt",
      type: :document,
      mime_type: "text/plain",
      file_size: 64,
      file_path: "/tmp/auth-test-file-#{System.unique_integer([:positive])}.txt",
      user_id: user.id
    }

    Magus.Files.File
    |> Ash.Changeset.for_create(:create_for_user, Map.merge(defaults, attrs))
    |> Ash.create(authorize?: false)
  end

  test "user cannot upsert folder state for another user's folder" do
    owner = generate(user())
    outsider = generate(user())
    folder = generate(folder(actor: owner))

    assert {:error, %Ash.Error.Invalid{}} =
             Chat.upsert_folder_expanded(%{folder_id: folder.id, is_expanded: true},
               actor: outsider
             )
  end

  test "user cannot set pane state for another user's conversation" do
    owner = generate(user())
    outsider = generate(user())
    conversation = generate(conversation(actor: owner))

    assert {:error, %Ash.Error.Invalid{}} =
             Chat.set_pane(conversation.id, outsider.id, :draft, Ash.UUIDv7.generate(),
               actor: outsider
             )
  end

  test "user cannot favorite an unreadable private prompt" do
    owner = generate(user())
    outsider = generate(user())

    {:ok, prompt} =
      Library.create_prompt(%{name: "Private", content: "secret", type: :user}, actor: owner)

    assert {:error, %Ash.Error.Forbidden{}} =
             Library.create_prompt_favorite(%{prompt_id: prompt.id}, actor: outsider)
  end

  test "outsider cannot read chunks for another user's file" do
    owner = generate(user())
    outsider = generate(user())

    {:ok, file} = create_file(owner, %{name: "doc.txt"})

    {:ok, _chunk} =
      Files.create_chunk(
        %{
          file_id: file.id,
          content: "secret chunk",
          position: 1,
          token_count: 2
        },
        authorize?: false
      )

    assert {:ok, []} = Files.get_chunks_for_file(file.id, actor: outsider)
  end

  test "outsider cannot read another user's message usage record" do
    owner = generate(user())
    outsider = generate(user())
    conversation = generate(conversation(actor: owner))
    model = generate(model())

    {:ok, message} =
      Chat.send_user_message(%{text: "hello", conversation_id: conversation.id}, actor: owner)

    {:ok, usage} =
      Magus.Usage.create_message_usage(
        %{
          user_id: owner.id,
          message_id: message.id,
          conversation_id: conversation.id,
          model_id: model.id,
          model_name: "test-model",
          prompt_tokens: 1,
          completion_tokens: 1,
          total_tokens: 2
        },
        authorize?: false
      )

    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
             Ash.get(Magus.Usage.MessageUsage, usage.id, actor: outsider)
  end

  test "user cannot create a message usage record via actor" do
    user = generate(user())
    conversation = generate(conversation(actor: user))
    model = generate(model())

    {:ok, message} =
      Chat.send_user_message(%{text: "hello", conversation_id: conversation.id}, actor: user)

    assert {:error, %Ash.Error.Forbidden{}} =
             Magus.Usage.create_message_usage(
               %{
                 user_id: user.id,
                 message_id: message.id,
                 conversation_id: conversation.id,
                 model_id: model.id,
                 model_name: "test-model",
                 prompt_tokens: 1,
                 completion_tokens: 1,
                 total_tokens: 2
               },
               actor: user
             )
  end

  test "user cannot create a file chunk via actor" do
    user = generate(user())
    {:ok, file} = create_file(user, %{name: "chunk-forbid.txt"})

    assert {:error, %Ash.Error.Forbidden{}} =
             Files.create_chunk(
               %{file_id: file.id, content: "nope", position: 0, token_count: 1},
               actor: user
             )
  end
end
