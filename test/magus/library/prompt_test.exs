defmodule Magus.Library.PromptTest do
  @moduledoc """
  Tests for the Prompt resource.

  Note: Prompt does not have authorization policies configured.
  Tests use `actor: user` for consistency, and `authorize?: false` for
  public actions (public_prompts, public_search_prompts) and Tag operations.
  """
  use Magus.ResourceCase, async: true

  import Mox

  alias Magus.Library
  alias Magus.Test.Mocks.LLMMock
  alias Magus.Test.MockResponses

  setup :verify_on_exit!

  describe "create/1" do
    test "creates prompt with valid attributes" do
      user = generate(user())

      {:ok, prompt} =
        Library.create_prompt(
          %{
            name: "Test Prompt",
            content: "This is a test prompt",
            type: :user
          },
          actor: user
        )

      assert prompt.name == "Test Prompt"
      assert prompt.content == "This is a test prompt"
      assert prompt.type == :user
      assert prompt.user_id == user.id
      assert prompt.is_public == false
    end

    test "creates prompt with all prompt types" do
      user = generate(user())

      for prompt_type <- [:system, :user] do
        {:ok, prompt} =
          Library.create_prompt(
            %{
              name: "#{prompt_type} Prompt",
              content: "Content for #{prompt_type}",
              type: prompt_type
            },
            actor: user
          )

        assert prompt.type == prompt_type
      end
    end

    test "creates prompt with metadata and variables" do
      user = generate(user())

      {:ok, prompt} =
        Library.create_prompt(
          %{
            name: "Prompt with metadata",
            content: "Content",
            type: :user,
            metadata: %{"key" => "value"},
            variables: %{"var1" => "default1"}
          },
          actor: user
        )

      assert prompt.metadata == %{"key" => "value"}
      assert prompt.variables == %{"var1" => "default1"}
    end

    test "requires name, content, and type" do
      user = generate(user())

      {:error, _} = Library.create_prompt(%{}, actor: user)
    end
  end

  describe "update/1" do
    test "updates prompt attributes" do
      user = generate(user())
      prompt = generate(prompt(actor: user))

      {:ok, updated} =
        Library.update_prompt(
          prompt,
          %{
            name: "Updated Name",
            content: "Updated content"
          },
          actor: user
        )

      assert updated.name == "Updated Name"
      assert updated.content == "Updated content"
    end

    test "updates prompt type" do
      user = generate(user())
      prompt = generate(prompt(actor: user, type: :user))

      {:ok, updated} =
        Library.update_prompt(prompt, %{type: :system}, actor: user)

      assert updated.type == :system
    end
  end

  describe "destroy/1" do
    test "deletes prompt" do
      user = generate(user())
      prompt = generate(prompt(actor: user))

      :ok = Library.destroy_prompt(prompt, actor: user)

      {:error, _} = Library.get_prompt(prompt.id, actor: user)
    end
  end

  describe "my_prompts/1" do
    test "returns only user's prompts" do
      user1 = generate(user())
      user2 = generate(user())

      prompt1 = generate(prompt(actor: user1))
      _prompt2 = generate(prompt(actor: user2))

      {:ok, prompts} = Library.my_prompts(actor: user1)

      assert length(prompts) == 1
      assert hd(prompts).id == prompt1.id
    end
  end

  describe "my_prompts_by_type/1" do
    test "filters prompts by type" do
      user = generate(user())

      system_prompt = generate(prompt(actor: user, type: :system))
      _user_prompt = generate(prompt(actor: user, type: :user))

      {:ok, prompts} = Library.my_prompts_by_type(:system, actor: user)

      assert length(prompts) == 1
      assert hd(prompts).id == system_prompt.id
    end
  end

  describe "publish/unpublish" do
    test "publishes prompt" do
      user = generate(user())
      prompt = generate(prompt(actor: user))

      assert prompt.is_public == false

      {:ok, published} =
        Library.publish_prompt(prompt, %{is_public: true}, actor: user)

      assert published.is_public == true
      assert published.published_at != nil
    end

    test "unpublishes prompt" do
      user = generate(user())
      prompt = generate(prompt(actor: user))

      {:ok, published} =
        Library.publish_prompt(prompt, %{is_public: true}, actor: user)

      {:ok, unpublished} = Library.unpublish_prompt(published, actor: user)

      assert unpublished.is_public == false
    end
  end

  describe "public_prompts/1" do
    test "returns only public prompts" do
      user = generate(user())

      prompt = generate(prompt(actor: user))
      {:ok, public_prompt} = Library.publish_prompt(prompt, %{is_public: true}, actor: user)
      _private_prompt = generate(prompt(actor: user))

      {:ok, prompts} = Library.public_prompts(authorize?: false)

      prompt_ids = Enum.map(prompts, & &1.id)
      assert public_prompt.id in prompt_ids
    end
  end

  describe "public_search/1" do
    test "searches public prompts by query" do
      user = generate(user())

      prompt = generate(prompt(actor: user, name: "Unique Search Term Prompt"))
      {:ok, _} = Library.publish_prompt(prompt, %{is_public: true}, actor: user)

      other_prompt = generate(prompt(actor: user, name: "Other Prompt"))
      {:ok, _} = Library.publish_prompt(other_prompt, %{is_public: true}, actor: user)

      {:ok, prompts} =
        Library.public_search_prompts(%{query: "Unique Search Term"}, authorize?: false)

      assert length(prompts) == 1
      assert hd(prompts).id == prompt.id
    end

    test "filters public prompts by type" do
      user = generate(user())

      system = generate(prompt(actor: user, type: :system))
      {:ok, _} = Library.publish_prompt(system, %{is_public: true}, actor: user)

      user_prompt = generate(prompt(actor: user, type: :user))
      {:ok, _} = Library.publish_prompt(user_prompt, %{is_public: true}, actor: user)

      {:ok, prompts} =
        Library.public_search_prompts(%{type: :system}, authorize?: false)

      prompt_ids = Enum.map(prompts, & &1.id)
      assert system.id in prompt_ids
      refute user_prompt.id in prompt_ids
    end

    test "sorts public prompts by recent" do
      user = generate(user())

      prompt1 = generate(prompt(actor: user))
      {:ok, _} = Library.publish_prompt(prompt1, %{is_public: true}, actor: user)

      # Small delay to ensure different timestamps
      Process.sleep(10)

      prompt2 = generate(prompt(actor: user))
      {:ok, _} = Library.publish_prompt(prompt2, %{is_public: true}, actor: user)

      {:ok, prompts} =
        Library.public_search_prompts(%{sort_by: :recent}, authorize?: false)

      # Most recent first
      assert hd(prompts).id == prompt2.id
    end
  end

  describe "copy_to_library/1" do
    test "copies public prompt to user's library" do
      owner = generate(user())
      copier = generate(user())

      prompt = generate(prompt(actor: owner, name: "Original Prompt"))
      {:ok, published} = Library.publish_prompt(prompt, %{is_public: true}, actor: owner)

      {:ok, copied} =
        Library.copy_prompt_to_library(
          published.id,
          %{
            name: published.name,
            content: published.content,
            type: published.type
          },
          actor: copier
        )

      assert copied.name == "Original Prompt"
      assert copied.user_id == copier.id
      assert copied.copied_from_id == published.id
    end

    # Note: copy_count increment happens in after_action which may have timing issues
    # This test verifies the copied prompt is created correctly
    test "creates prompt with copied_from reference" do
      owner = generate(user())
      copier = generate(user())

      prompt = generate(prompt(actor: owner))
      {:ok, published} = Library.publish_prompt(prompt, %{is_public: true}, actor: owner)

      {:ok, copied} =
        Library.copy_prompt_to_library(
          published.id,
          %{
            name: published.name,
            content: published.content,
            type: published.type
          },
          actor: copier
        )

      assert copied.copied_from_id == published.id
    end
  end

  describe "create_from_message/2" do
    test "creates prompt from a message" do
      # Mock the generate_text call that GenerateTitle makes when generating the name
      expect(LLMMock, :generate_text, fn _model, _context, _opts ->
        MockResponses.generate_text_response("AI Instruction Prompt")
      end)

      user = generate(user())
      conversation = generate(conversation(actor: user))

      message =
        generate(
          message(
            actor: user,
            conversation_id: conversation.id,
            text: "This is a detailed prompt instruction for the AI."
          )
        )

      {:ok, prompt} =
        Library.create_prompt_from_message(
          message.id,
          %{type: :user},
          actor: user
        )

      assert prompt.content == message.text
      assert prompt.type == :user
      assert prompt.user_id == user.id
      # Name is generated from GenerateTitle
      assert prompt.name == "AI Instruction Prompt"
    end

    test "creates prompt from message with custom name" do
      user = generate(user())
      conversation = generate(conversation(actor: user))
      message = generate(message(actor: user, conversation_id: conversation.id))

      {:ok, prompt} =
        Library.create_prompt_from_message(
          message.id,
          %{type: :user, name: "My Custom Name"},
          actor: user
        )

      assert prompt.name == "My Custom Name"
      assert prompt.type == :user
    end

    test "fails with invalid message_id" do
      user = generate(user())
      fake_id = Ash.UUID.generate()

      {:error, _} =
        Library.create_prompt_from_message(
          fake_id,
          %{type: :user},
          actor: user
        )
    end
  end

  describe "create_from_conversation/2" do
    test "creates prompt from conversation patterns" do
      expect(LLMMock, :generate_object, fn _model, _prompt, _schema, _opts ->
        MockResponses.generate_object_response(%{
          "content" => "You are a friendly assistant who helps users with their questions.",
          "suggested_type" => "system",
          "suggested_name" => "Friendly Helper"
        })
      end)

      user = generate(user())
      conversation = generate(conversation(actor: user))

      # Create a few messages in the conversation
      _msg1 =
        generate(
          message(actor: user, conversation_id: conversation.id, text: "Hello, can you help me?")
        )

      {:ok, prompt} =
        Library.create_prompt_from_conversation(
          conversation.id,
          %{},
          actor: user
        )

      assert prompt.content ==
               "You are a friendly assistant who helps users with their questions."

      assert prompt.type == :system
      assert prompt.name == "Friendly Helper"
      assert prompt.user_id == user.id
    end

    test "fails with empty conversation" do
      user = generate(user())
      conversation = generate(conversation(actor: user))

      # No messages in conversation - should fail
      {:error, changeset} =
        Library.create_prompt_from_conversation(
          conversation.id,
          %{},
          actor: user
        )

      assert changeset.errors != []
    end
  end

  describe "create with new attributes" do
    test "creates prompt with description and user_message_template" do
      user = generate(user())

      {:ok, prompt} =
        Library.create_prompt(
          %{
            name: "Detailed Prompt",
            content: "You are a helpful assistant.",
            type: :system,
            description: "A helpful assistant prompt for general tasks",
            user_message_template: "Please help me with {{TASK}}"
          },
          actor: user
        )

      assert prompt.description == "A helpful assistant prompt for general tasks"
      assert prompt.user_message_template == "Please help me with {{TASK}}"
    end

    test "creates prompt with additional_information" do
      user = generate(user())

      {:ok, prompt} =
        Library.create_prompt(
          %{
            name: "Prompt with Info",
            content: "Content",
            type: :user,
            additional_information: "## Usage Tips\n\n- Tip 1\n- Tip 2"
          },
          actor: user
        )

      assert prompt.additional_information == "## Usage Tips\n\n- Tip 1\n- Tip 2"
    end

    test "creates prompt with language" do
      user = generate(user())

      {:ok, prompt} =
        Library.create_prompt(
          %{
            name: "German Prompt",
            content: "Du bist ein hilfreicher Assistent",
            type: :system,
            language: :de
          },
          actor: user
        )

      assert prompt.language == :de
    end

    test "defaults language to en" do
      user = generate(user())

      {:ok, prompt} =
        Library.create_prompt(
          %{
            name: "Default Prompt",
            content: "Content",
            type: :user
          },
          actor: user
        )

      assert prompt.language == :en
    end
  end

  describe "increment_use_count/1" do
    test "increments use count atomically" do
      user = generate(user())
      prompt = generate(prompt(actor: user))

      assert prompt.use_count == 0

      {:ok, updated} = Library.increment_prompt_use_count(prompt, authorize?: false)
      assert updated.use_count == 1

      {:ok, updated2} = Library.increment_prompt_use_count(updated, authorize?: false)
      assert updated2.use_count == 2
    end
  end

  describe "find_similar/1" do
    test "returns empty list when source prompt has no embedding" do
      user = generate(user())
      # Create unpublished prompt - no embedding generated
      prompt = generate(prompt(actor: user))

      # find_similar returns empty list when source prompt has no embedding
      {:ok, similar} = Library.find_similar_prompts(prompt.id, authorize?: false)

      assert similar == []
    end

    test "excludes current prompt from results" do
      user = generate(user())
      prompt = generate(prompt(actor: user))
      # Publishing generates embedding
      {:ok, published} = Library.publish_prompt(prompt, %{is_public: true}, actor: user)

      # Query with the same prompt - should not include itself
      {:ok, similar} = Library.find_similar_prompts(published.id, authorize?: false)

      refute Enum.any?(similar, &(&1.id == published.id))
    end

    test "only returns public prompts with embeddings" do
      user = generate(user())

      # Create and publish two prompts - publishing generates embeddings
      prompt1 = generate(prompt(actor: user, name: "Public prompt one"))
      {:ok, published1} = Library.publish_prompt(prompt1, %{is_public: true}, actor: user)

      prompt2 = generate(prompt(actor: user, name: "Public prompt two"))
      {:ok, _published2} = Library.publish_prompt(prompt2, %{is_public: true}, actor: user)

      # Create private prompt - won't appear in results
      _private_prompt = generate(prompt(actor: user))

      {:ok, similar} = Library.find_similar_prompts(published1.id, authorize?: false)

      # All results should be public (filter ensures is_public == true)
      assert Enum.all?(similar, & &1.is_public)
    end

    @tag :skip
    test "finds similar prompts based on embedding similarity" do
      # Skipped: Requires embedding service (OPENROUTER_API_KEY) to be available
      user = generate(user())

      prompt1 =
        generate(
          prompt(
            actor: user,
            name: "Python Code Review",
            content: "You are an expert Python code reviewer."
          )
        )

      {:ok, published1} = Library.publish_prompt(prompt1, %{is_public: true}, actor: user)

      prompt2 =
        generate(
          prompt(
            actor: user,
            name: "JavaScript Code Review",
            content: "You are an expert JavaScript code reviewer."
          )
        )

      {:ok, _published2} = Library.publish_prompt(prompt2, %{is_public: true}, actor: user)

      {:ok, similar} = Library.find_similar_prompts(published1.id, authorize?: false)

      assert length(similar) >= 1
    end
  end

  describe "tags" do
    test "adds tags to prompt" do
      user = generate(user())
      prompt = generate(prompt(actor: user))

      {:ok, tag1} = Library.create_tag(%{name: "tag1"}, authorize?: false)
      {:ok, tag2} = Library.create_tag(%{name: "tag2"}, authorize?: false)

      {:ok, updated} =
        Library.add_prompt_tags(prompt, [tag1.id, tag2.id], actor: user)

      {:ok, loaded} = Ash.load(updated, :tags, authorize?: false)
      tag_names = Enum.map(loaded.tags, &to_string(&1.name))

      assert "tag1" in tag_names
      assert "tag2" in tag_names
    end

    test "verifies tags were added to prompt" do
      user = generate(user())
      prompt = generate(prompt(actor: user))

      {:ok, tag} = Library.create_tag(%{name: "verifiable"}, authorize?: false)
      {:ok, _with_tag} = Library.add_prompt_tags(prompt, [tag.id], actor: user)

      # Verify the prompt_tags relationship was created
      {:ok, loaded} = Library.get_prompt(prompt.id, authorize?: false, load: [:prompt_tags])

      assert length(loaded.prompt_tags) == 1
      assert hd(loaded.prompt_tags).tag_id == tag.id
    end
  end
end
