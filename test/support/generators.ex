defmodule Magus.Generators do
  @moduledoc """
  Test data generators using Ash.Generator.

  These generators create valid records directly in the database.
  Use `generate/1` for single records and `generate_many/2` for multiple.

  ## Examples

      # Create a single user
      user = generate(user())

      # Create a user with specific attributes
      admin = generate(user(is_admin: true))

      # Create multiple conversations
      conversations = generate_many(conversation(actor: user), 5)

  ## Pattern Inconsistency Note

  Most generators (user/1, conversation/1, message/1, etc.) use `changeset_generator/3`
  and return a generator spec that must be passed to `generate/1`:

      user = generate(user())

  However, Workflows domain generators (job/1, job_run/1, notification_preference/1)
  return records directly due to complex foreign key dependencies and the need to
  use relate_actor for user association:

      job = job(conversation_id: conv.id, user_id: user.id)  # Returns record directly

  This inconsistency exists because:
  1. Jobs require a valid user to be passed as actor for relate_actor
  2. Jobs require a valid conversation_id foreign key
  3. The changeset_generator approach doesn't easily support this pattern

  Future improvement: Consider renaming to create_job/1, create_job_run/1, etc.
  to make the different behavior explicit.
  """

  use Ash.Generator

  alias Magus.Accounts
  alias Magus.Chat
  alias Magus.Library

  # ---------------------------------------------------------------------------
  # Accounts Domain
  # ---------------------------------------------------------------------------

  @doc """
  Generates a valid user with unique email.

  ## Examples

      user = generate(user())
  """
  def user(opts \\ []) do
    unique_id = "#{System.unique_integer([:positive, :monotonic])}-#{:rand.uniform(1_000_000)}"
    password = Keyword.get(opts, :password, "Password123!")
    email = Keyword.get(opts, :email, "user-#{unique_id}@test.com")

    changeset_generator(
      Accounts.User,
      :register_with_password,
      defaults: %{
        email: email,
        password: password,
        password_confirmation: password,
        display_name: Keyword.get(opts, :display_name),
        language: Keyword.get(opts, :language, :en),
        name: Keyword.get(opts, :name, "Test User"),
        accepted_terms: Keyword.get(opts, :accepted_terms, true),
        accepted_age_requirement: Keyword.get(opts, :accepted_age_requirement, true)
      },
      authorize?: false
    )
  end

  @doc """
  Generates a valid API token. Pass `:actor` to set the owner.

  Returns `{token, plaintext}` because plaintext is only available
  from the create result.

  ## Examples

      {token, plaintext} = api_token(actor: user)
      {token, _plaintext} = api_token(actor: user, scope: :write, workspace_id: ws.id)
  """
  def api_token(opts) do
    actor = Keyword.fetch!(opts, :actor)

    attrs = %{
      name: Keyword.get(opts, :name, "Test token #{System.unique_integer([:positive])}"),
      scope: Keyword.get(opts, :scope, :read),
      created_via: Keyword.get(opts, :created_via, :settings),
      workspace_id: Keyword.get(opts, :workspace_id),
      expires_at: Keyword.get(opts, :expires_at)
    }

    {:ok, %{token: token, plaintext: plaintext}} = Accounts.create_api_token(attrs, actor: actor)
    {token, plaintext}
  end

  @doc """
  Ensures a user is on a "pro" plan. Now that workspace creation is unrestricted,
  this is mostly used to give tests a stable plan with reasonable limits.
  """
  def ensure_workspace_plan(user) do
    require Ash.Query

    plan =
      case Magus.Usage.Policy
           |> Ash.Query.filter(key == "pro")
           |> Ash.read_one(authorize?: false) do
        {:ok, %{} = plan} ->
          plan

        {:ok, nil} ->
          Magus.Usage.Policy
          |> Ash.Changeset.for_create(
            :create,
            %{
              key: "pro",
              name: "Pro",
              price_monthly_cents: 3000,
              storage_bytes: 53_687_091_200,
              max_upload_bytes: 104_857_600,
              image_generation_enabled: true,
              video_generation_enabled: true,
              sponsorable_seats: nil,
              is_active: true,
              sort_order: 2
            },
            authorize?: false
          )
          |> Ash.create!(authorize?: false)
      end

    upsert_personal_subscription(user, plan)
    user
  end

  @doc """
  Ensures a user has a personal subscription on a plan that lets them sponsor seats.

  Options:
    * `:sponsorable_seats` - Number of included sponsored seats (default: 5)
    * `:key` - Plan key (default: "sponsoring-test")

  Returns the plan.
  """
  def ensure_sponsoring_plan(user, opts \\ []) do
    require Ash.Query

    sponsorable_seats = Keyword.get(opts, :sponsorable_seats, 5)
    key = Keyword.get(opts, :key, "sponsoring-test-#{System.unique_integer([:positive])}")

    plan =
      Magus.Usage.Policy
      |> Ash.Changeset.for_create(
        :create,
        %{
          key: key,
          name: "Sponsoring Test #{key}",
          price_monthly_cents: 6000,
          storage_bytes: 107_374_182_400,
          max_upload_bytes: 209_715_200,
          image_generation_enabled: true,
          video_generation_enabled: true,
          sponsorable_seats: sponsorable_seats,
          is_active: true,
          sort_order: 99
        },
        authorize?: false
      )
      |> Ash.create!(authorize?: false)

    upsert_personal_subscription(user, plan)
    plan
  end

  @doc """
  Ensures a user has a personal subscription on a plan that does NOT permit
  sponsoring seats (`sponsorable_seats == nil`). Useful for testing rejection
  of `:invite` for non-sponsoring plans. Returns the plan.
  """
  def ensure_no_sponsoring_plan(user) do
    require Ash.Query

    key = "no-sponsoring-test-#{System.unique_integer([:positive])}"

    plan =
      Magus.Usage.Policy
      |> Ash.Changeset.for_create(
        :create,
        %{
          key: key,
          name: "No Sponsoring Test #{key}",
          price_monthly_cents: 1000,
          storage_bytes: 100 * 1024 * 1024,
          max_upload_bytes: 10 * 1024 * 1024,
          image_generation_enabled: false,
          video_generation_enabled: false,
          sponsorable_seats: nil,
          is_active: true,
          sort_order: 1
        },
        authorize?: false
      )
      |> Ash.create!(authorize?: false)

    upsert_personal_subscription(user, plan)
    plan
  end

  defp upsert_personal_subscription(user, plan) do
    require Ash.Query

    case Magus.Usage.Account
         |> Ash.Query.filter(user_id == ^user.id and is_nil(sponsor_user_id))
         |> Ash.read_one(authorize?: false) do
      {:ok, %{} = sub} ->
        sub
        |> Ash.Changeset.for_update(:update, %{usage_plan_id: plan.id}, authorize?: false)
        |> Ash.update!(authorize?: false)

      _ ->
        Magus.Usage.Account
        |> Ash.Changeset.for_create(
          :create,
          %{
            user_id: user.id,
            usage_plan_id: plan.id,
            status: :active,
            storage_usage_bytes: 0
          },
          authorize?: false
        )
        |> Ash.create!(authorize?: false)
    end
  end

  # ---------------------------------------------------------------------------
  # Chat Domain
  # ---------------------------------------------------------------------------

  @doc """
  Generates a conversation.

  ## Options
    * `:actor` - The user who owns the conversation (required in most cases)
    * `:title` - Override the title
    * `:chat_mode` - Set chat mode (default: :chat)

  ## Examples

      conversation = generate(conversation(actor: user))
  """
  def conversation(opts \\ []) do
    unique_id = System.unique_integer([:positive])
    actor = Keyword.get(opts, :actor)

    changeset_generator(
      Chat.Conversation,
      :create,
      defaults: %{
        title: Keyword.get(opts, :title, "Test Conversation #{unique_id}"),
        chat_mode: Keyword.get(opts, :chat_mode, :chat),
        folder_id: Keyword.get(opts, :folder_id),
        is_task_conversation: Keyword.get(opts, :is_task_conversation, false),
        parent_conversation_id: Keyword.get(opts, :parent_conversation_id),
        sandbox_conversation_id: Keyword.get(opts, :sandbox_conversation_id, nil),
        system_prompt: Keyword.get(opts, :system_prompt),
        # Explicitly set to nil to prevent state leakage between tests
        selected_model_id: Keyword.get(opts, :selected_model_id, nil),
        custom_agent_id: Keyword.get(opts, :custom_agent_id, nil),
        workspace_id: Keyword.get(opts, :workspace_id, nil)
      },
      actor: actor
    )
  end

  @doc """
  Generates a message.

  ## Options
    * `:actor` - The user who created the message
    * `:conversation_id` - The conversation to add the message to (required)
    * `:text` - The message text

  ## Examples

      message = generate(message(actor: user, conversation_id: conv.id, text: "Hello!"))
  """
  def message(opts \\ []) do
    unique_id = System.unique_integer([:positive])
    actor = Keyword.get(opts, :actor)

    changeset_generator(
      Chat.Message,
      :create,
      defaults: %{
        text: Keyword.get(opts, :text, "Test message #{unique_id}"),
        conversation_id: Keyword.get(opts, :conversation_id),
        mode: Keyword.get(opts, :mode, :chat),
        # Explicitly set to nil to prevent state leakage between tests
        selected_model_id: Keyword.get(opts, :selected_model_id, nil)
      },
      actor: actor
    )
  end

  @doc """
  Generates a folder.

  ## Options
    * `:actor` - The user who owns the folder (required)
    * `:name` - Override the folder name
    * `:parent_id` - Nest under another folder

  ## Examples

      folder = generate(folder(actor: user))
  """
  def folder(opts \\ []) do
    unique_id = System.unique_integer([:positive])
    actor = Keyword.get(opts, :actor)

    changeset_generator(
      Chat.Folder,
      :create,
      defaults: %{
        name: Keyword.get(opts, :name, "Test Folder #{unique_id}"),
        parent_id: Keyword.get(opts, :parent_id),
        workspace_id: Keyword.get(opts, :workspace_id),
        kind: Keyword.get(opts, :kind, :conversations)
      },
      actor: actor
    )
  end

  @doc """
  Generates a file.

  Pass either `:actor` (user) or `:user_id` (uuid). When `:user_id` is given
  the generator uses the `:create_for_user` action with `authorize?: false`,
  which skips storage-limit and folder-context validations that aren't
  relevant in most extraction tests.

  ## Options
    * `:actor` - The user who owns the file
    * `:user_id` - Alternative to `:actor`; the user UUID
    * `:name` - File name (default: "test-{unique_id}.txt")
    * `:type` - File type (default: `:text`)
    * `:mime_type` - MIME type (default: "text/plain")
    * `:file_size` - Size in bytes (default: 1024)
    * `:file_path` - Storage path (default: "tmp/test-{unique_id}.txt")
    * `:folder_id` - Folder to place the file in
    * `:conversation_id` - Conversation to attach the file to
    * `:workspace_id` - Workspace the file lives in

  ## Examples

      file = generate(file(actor: user))
      file = generate(file(actor: user, folder_id: folder.id))
      file = generate(file(user_id: user.id, type: :document))
  """
  def file(opts \\ []) do
    unique_id = System.unique_integer([:positive])
    actor = Keyword.get(opts, :actor)
    user_id = Keyword.get(opts, :user_id)

    base_defaults = %{
      name: Keyword.get(opts, :name, "test-#{unique_id}.txt"),
      type: Keyword.get(opts, :type, :text),
      mime_type: Keyword.get(opts, :mime_type, "text/plain"),
      file_size: Keyword.get(opts, :file_size, 1024),
      file_path: Keyword.get(opts, :file_path, "tmp/test-#{unique_id}.txt"),
      folder_id: Keyword.get(opts, :folder_id),
      conversation_id: Keyword.get(opts, :conversation_id),
      workspace_id: Keyword.get(opts, :workspace_id),
      # Explicitly nil to avoid Ash.Generator generating bogus UUIDs for unspecified fields
      is_template: Keyword.get(opts, :is_template, false),
      uploaded_via_agent_id: Keyword.get(opts, :uploaded_via_agent_id),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    cond do
      is_binary(user_id) ->
        changeset_generator(
          Magus.Files.File,
          :create_for_user,
          defaults: Map.put(base_defaults, :user_id, user_id),
          authorize?: false
        )

      true ->
        changeset_generator(
          Magus.Files.File,
          :create,
          defaults: base_defaults,
          actor: actor
        )
    end
  end

  @doc """
  Generates a file chunk.

  Chunk writes are forbidden through user-facing policy, so this generator
  always runs with `authorize?: false` (matching the file-processing pipeline).

  ## Options
    * `:file_id` - Parent file UUID (required)
    * `:content` - Chunk text content (default: auto-generated)
    * `:position` - Position within the file (default: 0)
    * `:token_count` - Approximate token count (default: derived from content)
    * `:metadata` - Optional metadata map

  ## Examples

      chunk = generate(chunk(file_id: file.id, content: "Some text"))
  """
  def chunk(opts \\ []) do
    unique_id = System.unique_integer([:positive])
    content = Keyword.get(opts, :content, "Test chunk content #{unique_id}")
    token_count = Keyword.get(opts, :token_count, max(div(byte_size(content), 4), 1))

    changeset_generator(
      Magus.Files.Chunk,
      :create,
      defaults: %{
        file_id: Keyword.fetch!(opts, :file_id),
        content: content,
        position: Keyword.get(opts, :position, 0),
        token_count: token_count,
        metadata: Keyword.get(opts, :metadata, %{}),
        # The pgvector type has no Ash.Generator implementation; default to nil
        # so Ash.Generator doesn't try to synthesize a value.
        embedding: Keyword.get(opts, :embedding, nil)
      },
      authorize?: false
    )
  end

  @doc """
  Generates an AI model.

  ## Options
    * `:name` - Model display name
    * `:provider` - Provider name (default: "test")
    * `:key` - Model identifier key (default: "test/model-{unique_id}")
    * `:active?` - Whether model is active (default: true)
    * `:input_cost_value` - Numeric input cost (default: Decimal.new("1"))
    * `:input_cost_unit` - Input cost unit (default: :per_million_tokens)
    * `:output_cost_value` - Numeric output cost (default: Decimal.new("2"))
    * `:output_cost_unit` - Output cost unit (default: :per_million_tokens)

  ## Examples

      model = generate(model())
      image_model = generate(model(output_cost_unit: :per_image, output_cost_value: Decimal.new("0.04")))
  """
  def model(opts \\ []) do
    unique_id = System.unique_integer([:positive])

    defaults = %{
      name: Keyword.get(opts, :name, "Test Model #{unique_id}"),
      provider: Keyword.get(opts, :provider, "test"),
      key: Keyword.get(opts, :key, "test/model-#{unique_id}"),
      active?: Keyword.get(opts, :active?, true),
      # Structured cost fields
      input_cost_value: Keyword.get(opts, :input_cost_value, Decimal.new("1")),
      input_cost_unit: Keyword.get(opts, :input_cost_unit, :per_million_tokens),
      output_cost_value: Keyword.get(opts, :output_cost_value, Decimal.new("2")),
      output_cost_unit: Keyword.get(opts, :output_cost_unit, :per_million_tokens),
      input_modalities: Keyword.get(opts, :input_modalities, ["text"]),
      output_modalities: Keyword.get(opts, :output_modalities, ["text"]),
      # Pin to nil so the generator doesn't invent FK values that don't exist
      model_provider_id: Keyword.get(opts, :model_provider_id, nil),
      # Pin so the generator doesn't invent random metadata maps
      llm_metadata: Keyword.get(opts, :llm_metadata, %{}),
      internal?: Keyword.get(opts, :internal?, false)
    }

    changeset_generator(
      Chat.Model,
      :create,
      defaults: defaults,
      authorize?: false
    )
  end

  @doc """
  Creates a routing slot directly (not a generator).

  ## Options
    * `:model_id` - The model ID (required)
    * `:specialty` - Routing specialty atom (required)
    * `:tier` - Routing tier atom (required)

  ## Examples

      routing_slot(model_id: model.id, specialty: :coding, tier: :complex)
  """
  def routing_slot(opts) do
    model_id = Keyword.fetch!(opts, :model_id)
    specialty = Keyword.fetch!(opts, :specialty)
    tier = Keyword.fetch!(opts, :tier)

    {:ok, slot} =
      Magus.Chat.upsert_routing_slot(model_id, specialty, tier, authorize?: false)

    slot
  end

  @doc """
  Creates a thread conversation directly (not a generator).

  Threads have complex dependencies (parent conversation + branch message),
  so we create them directly rather than using changeset_generator.

  ## Options
    * `:actor` - The user who creates the thread (required)
    * `:conversation` - Parent conversation (default: auto-generated)
    * `:message` - Message to branch from (default: auto-generated in parent)

  ## Examples

      thread = thread(actor: user)
      thread = thread(actor: user, conversation: conv, message: msg)
  """
  def thread(attrs \\ %{}) do
    actor = attrs[:actor] || raise "thread/1 requires :actor"
    conversation = attrs[:conversation] || generate(conversation(actor: actor))
    message = attrs[:message] || generate(message(conversation_id: conversation.id, actor: actor))

    {:ok, thread} =
      Chat.create_thread(
        %{
          parent_conversation_id: conversation.id,
          branched_at_message_id: message.id
        },
        actor: actor
      )

    thread
  end

  # ---------------------------------------------------------------------------
  # Library Domain
  # ---------------------------------------------------------------------------

  @doc """
  Generates a prompt.

  ## Options
    * `:actor` - The user who owns the prompt (required)
    * `:name` - Override the prompt name
    * `:content` - The prompt content/text
    * `:type` - Prompt type: :system, :user (default: :user)

  ## Examples

      prompt = generate(prompt(actor: user))
  """
  def prompt(opts \\ []) do
    unique_id = System.unique_integer([:positive])
    actor = Keyword.get(opts, :actor)

    changeset_generator(
      Library.Prompt,
      :create,
      defaults: %{
        name: Keyword.get(opts, :name, "Test Prompt #{unique_id}"),
        content: Keyword.get(opts, :content, "Test content for prompt #{unique_id}"),
        type: Keyword.get(opts, :type, :user),
        # Explicitly set to nil to prevent random UUID generation
        chat_mode: Keyword.get(opts, :chat_mode, nil),
        model_id: Keyword.get(opts, :model_id, nil),
        workspace_id: Keyword.get(opts, :workspace_id, nil)
      },
      actor: actor
    )
  end

  # ---------------------------------------------------------------------------
  # Memory Domain
  # ---------------------------------------------------------------------------

  alias Magus.Memory

  @doc """
  Creates a memory directly (not a generator).

  Supports all three scopes: `:local` (default, requires `:conversation_id`),
  `:user` (requires `:user_id`, optional `:workspace_id`), and `:agent`
  (requires `:user_id` and `:custom_agent_id`).

  ## Options
    * `:scope` - One of `:local | :user | :agent` (default: `:local`)
    * `:user_id` - The user ID (required for all scopes)
    * `:conversation_id` - The conversation the memory belongs to (required for `:local`)
    * `:custom_agent_id` - The agent the memory belongs to (required for `:agent`)
    * `:workspace_id` - Optional workspace for `:user` scope
    * `:name` - Memory name (default: auto-generated)
    * `:summary` - Memory summary
    * `:content` - Memory content map

  ## Examples

      memory(conversation_id: conv.id, user_id: user.id)
      memory(user_id: user.id, scope: :user, summary: "User is in Berlin")
      memory(user_id: user.id, scope: :agent, custom_agent_id: agent.id)
  """
  def memory(opts \\ []) do
    unique_id = System.unique_integer([:positive])
    scope = Keyword.get(opts, :scope, :local)
    user_id = Keyword.fetch!(opts, :user_id)

    attrs = %{
      name: Keyword.get(opts, :name, "Test Memory #{unique_id}"),
      summary: Keyword.get(opts, :summary, "Summary for test memory #{unique_id}"),
      content: Keyword.get(opts, :content, %{"test_key" => "test_value_#{unique_id}"})
    }

    case scope do
      :local ->
        conversation_id = Keyword.fetch!(opts, :conversation_id)

        {:ok, memory} =
          Memory.create_memory(conversation_id, user_id, attrs.name, attrs, authorize?: false)

        memory

      :user ->
        workspace_id = Keyword.get(opts, :workspace_id)

        {:ok, memory} =
          Memory.create_user_memory(user_id, workspace_id, attrs.name, attrs, authorize?: false)

        memory

      :agent ->
        custom_agent_id = Keyword.fetch!(opts, :custom_agent_id)

        {:ok, memory} =
          Memory.create_agent_memory(user_id, custom_agent_id, attrs, authorize?: false)

        memory
    end
  end

  # ---------------------------------------------------------------------------
  # Drafts Domain
  # ---------------------------------------------------------------------------

  @doc """
  Creates a draft directly (not a generator).

  Drafts are collaborative scratchpads scoped to a conversation. The
  `content` argument is markdown which the create action converts to a
  ProseMirror JSON document before storing it as the `content` attribute.

  ## Options
    * `:user_id` - The user who owns the draft (required)
    * `:conversation_id` - Parent conversation (default: auto-generated)
    * `:title` - Draft title (default: auto-generated)
    * `:content` - Markdown content (default: auto-generated paragraph)

  ## Examples

      draft = draft(user_id: user.id)
      draft = draft(user_id: user.id, conversation_id: conv.id, content: "scratch")
  """
  def draft(opts \\ []) do
    user_id = Keyword.fetch!(opts, :user_id)
    unique_id = System.unique_integer([:positive])

    {:ok, owner} = Magus.Accounts.get_user(user_id, authorize?: false)

    conversation_id =
      Keyword.get_lazy(opts, :conversation_id, fn ->
        generate(conversation(actor: owner)).id
      end)

    title = Keyword.get(opts, :title, "Test Draft #{unique_id}")
    content = Keyword.get(opts, :content, "Test draft body #{unique_id}")

    {:ok, draft} =
      Magus.Drafts.create_draft(conversation_id, title, content, user_id, actor: owner)

    draft
  end

  # ---------------------------------------------------------------------------
  # Workflows Domain
  # ---------------------------------------------------------------------------

  alias Magus.Workflows
  alias Magus.Usage

  # ---------------------------------------------------------------------------
  # Usage Domain
  # ---------------------------------------------------------------------------

  @doc """
  Generates a usage plan.

  ## Options
    * `:key` - Plan identifier key (default: auto-generated)
    * `:name` - Plan display name
    * `:storage_bytes` - Storage limit in bytes (default: 100MB)
    * `:max_upload_bytes` - Max upload size (default: 10MB)
    * `:is_active` - Whether plan is active (default: true)
    * `:sponsorable_seats` - Included sponsored seats (default: nil = cannot sponsor)

  ## Examples

      plan = generate(usage_plan())
      free_plan = generate(usage_plan(key: "free", name: "Free"))
      sponsoring_plan = generate(usage_plan(sponsorable_seats: 5))
  """
  def usage_plan(opts \\ []) do
    unique_id = System.unique_integer([:positive])

    defaults = %{
      key: Keyword.get(opts, :key, "test-plan-#{unique_id}"),
      name: Keyword.get(opts, :name, "Test Plan #{unique_id}"),
      description: Keyword.get(opts, :description, "Test plan description"),
      storage_bytes: Keyword.get(opts, :storage_bytes, 100 * 1024 * 1024),
      max_upload_bytes: Keyword.get(opts, :max_upload_bytes, 10 * 1024 * 1024),
      image_generation_enabled: Keyword.get(opts, :image_generation_enabled, true),
      video_generation_enabled: Keyword.get(opts, :video_generation_enabled, true),
      is_active: Keyword.get(opts, :is_active, true),
      sort_order: Keyword.get(opts, :sort_order, 0),
      max_routing_tier: Keyword.get(opts, :max_routing_tier, :simple),
      sponsorable_seats: Keyword.get(opts, :sponsorable_seats, nil)
    }

    changeset_generator(
      Usage.Policy,
      :create,
      defaults: defaults,
      authorize?: false
    )
  end

  @doc """
  Creates the free plan if it doesn't exist. Returns the existing plan if it does.

  This is used by tests that depend on the free plan existing.

  ## Examples

      free_plan = ensure_free_plan()
  """
  def ensure_free_plan do
    case Usage.get_free_plan(authorize?: false) do
      {:ok, plan} ->
        plan

      {:error, _} ->
        # Create the free plan with standard limits
        {:ok, plan} =
          Usage.Policy
          |> Ash.Changeset.for_create(:create, %{
            key: "free",
            name: "Free",
            description: "Free tier with limited usage",
            storage_bytes: 100 * 1024 * 1024,
            max_upload_bytes: 10 * 1024 * 1024,
            image_generation_enabled: false,
            video_generation_enabled: false,
            is_active: true,
            sort_order: 0
          })
          |> Ash.create(authorize?: false)

        plan
    end
  end

  def ensure_payg_plan do
    case Usage.get_plan_by_key("payg", authorize?: false) do
      {:ok, plan} when not is_nil(plan) ->
        plan

      _ ->
        {:ok, plan} =
          Usage.Policy
          |> Ash.Changeset.for_create(:create, %{
            key: "payg",
            name: "Pay-as-you-go",
            description: "Base fee + usage at cost",
            storage_bytes: 53_687_091_200,
            max_upload_bytes: 104_857_600,
            max_routing_tier: :complex,
            image_generation_enabled: true,
            video_generation_enabled: true,
            is_active: false,
            sort_order: 10
          })
          |> Ash.create(authorize?: false)

        plan
    end
  end

  @doc """
  Creates a workflow job directly (not a generator).

  Jobs have foreign key dependencies on conversations and users,
  so we create them directly rather than using changeset_generator.

  ## Options
    * `:conversation_id` - The conversation the job belongs to (required)
    * `:user_id` - The user ID (required) - used as actor for relate_actor
    * `:name` - Job name
    * `:trigger_prompt` - The prompt to execute
    * `:schedule_type` - :cron or :one_time (default: :one_time)
    * `:scheduled_at` - For one-time jobs
    * `:cron_expression` - For cron jobs
    * `:starts_at` - When job becomes active
    * `:ends_at` - When job stops (required for cron)

  ## Examples

      job = job(conversation_id: conv.id, user_id: user.id)
  """
  def job(opts \\ []) do
    unique_id = System.unique_integer([:positive])
    schedule_type = Keyword.get(opts, :schedule_type, :one_time)
    conversation_id = Keyword.fetch!(opts, :conversation_id)
    user_id = Keyword.fetch!(opts, :user_id)

    # Get the user to pass as actor for relate_actor
    {:ok, user} = Magus.Accounts.get_user(user_id, authorize?: false)

    attrs = %{
      name: Keyword.get(opts, :name, "Test Job #{unique_id}"),
      description: Keyword.get(opts, :description, "Test job description"),
      trigger_prompt: Keyword.get(opts, :trigger_prompt, "Execute test task #{unique_id}"),
      schedule_type: schedule_type,
      starts_at: Keyword.get(opts, :starts_at, DateTime.utc_now()),
      memory_name: Keyword.get(opts, :memory_name)
    }

    # Add schedule-type specific attributes
    attrs =
      case schedule_type do
        :one_time ->
          Map.put(
            attrs,
            :scheduled_at,
            Keyword.get(opts, :scheduled_at, DateTime.add(DateTime.utc_now(), 1, :hour))
          )

        :cron ->
          attrs
          |> Map.put(:cron_expression, Keyword.get(opts, :cron_expression, "0 9 * * *"))
          |> Map.put(
            :ends_at,
            Keyword.get(opts, :ends_at, DateTime.add(DateTime.utc_now(), 30, :day))
          )
      end

    # Create using domain function with actor for relate_actor, bypass auth
    {:ok, job} = Workflows.create_job(conversation_id, attrs, actor: user, authorize?: false)
    job
  end

  @doc """
  Creates a job run directly.

  ## Options
    * `:job_id` - The job this run belongs to (required)
    * `:metadata` - Optional metadata map

  ## Examples

      run = generate(job_run(job_id: job.id))
  """
  def job_run(opts \\ []) do
    job_id = Keyword.fetch!(opts, :job_id)
    metadata = Keyword.get(opts, :metadata, %{})

    {:ok, run} = Workflows.create_job_run(job_id, %{metadata: metadata}, authorize?: false)
    run
  end

  @doc """
  Creates a notification preference directly.

  ## Options
    * `:job_id` - The job this preference belongs to (required)
    * `:notify_on_success` - Whether to notify on success (default: false)
    * `:notify_on_failure` - Whether to notify on failure (default: true)
    * `:notification_channels` - List of channels (default: [:in_app])

  ## Examples

      pref = generate(notification_preference(job_id: job.id))
  """
  def notification_preference(opts \\ []) do
    job_id = Keyword.fetch!(opts, :job_id)

    attrs = %{
      notify_on_success: Keyword.get(opts, :notify_on_success, false),
      notify_on_failure: Keyword.get(opts, :notify_on_failure, true),
      notification_channels: Keyword.get(opts, :notification_channels, [:in_app])
    }

    {:ok, pref} = Workflows.create_notification_preference(job_id, attrs, authorize?: false)
    pref
  end

  # ---------------------------------------------------------------------------
  # Agents Domain
  # ---------------------------------------------------------------------------

  @doc """
  Creates a custom agent directly (not a generator).

  ## Options
    * `:name` - Agent name (default: auto-generated)
    * `:instructions` - Agent instructions (default: "You are a test agent.")

  ## Examples

      agent = custom_agent(user)
      agent = custom_agent(user, %{name: "My Agent", instructions: "Be helpful."})
  """
  def custom_agent(user, attrs \\ %{}) do
    defaults = %{
      name: "Test Agent #{System.unique_integer([:positive])}",
      instructions: "You are a test agent."
    }

    Magus.Agents.create_custom_agent!(Map.merge(defaults, attrs), actor: user)
  end

  @doc """
  Creates an agent run directly (not a generator).

  Agent runs track consult/delegate/subtask executions.

  ## Options
    * `:source_conversation_id` - Source conversation ID (required, legacy option name)
    * `:target_conversation_id` - Target conversation ID (optional, legacy option name)
    * `:model_key` - Model key (default: "openrouter:anthropic/claude-sonnet-4")
    * `:objective` - Task objective (default: auto-generated)
    * `:target_agent_id` - Target custom agent ID (optional, legacy option name)
    * `:kind` - Run kind (default: `:subtask`)
    * `:metadata` - Metadata map (default: %{})

  ## Examples

      run = sub_agent_run(source_conversation_id: conv.id)
  """
  def sub_agent_run(opts \\ []) do
    unique_id = System.unique_integer([:positive])
    source_conversation_id = Keyword.fetch!(opts, :source_conversation_id)
    request_id = Keyword.get(opts, :request_id, "test-run-#{Ash.UUIDv7.generate()}")

    attrs = %{
      kind: Keyword.get(opts, :kind, :subtask),
      source: Keyword.get(opts, :source, :mention),
      source_conversation_id: source_conversation_id,
      source_message_id: Keyword.get(opts, :source_message_id),
      target_conversation_id: Keyword.get(opts, :target_conversation_id),
      target_agent_id: Keyword.get(opts, :target_agent_id),
      initiator_user_id: Keyword.get(opts, :initiator_user_id),
      request_id: request_id,
      idempotency_key: Keyword.get(opts, :idempotency_key),
      model_key: Keyword.get(opts, :model_key, "openrouter:anthropic/claude-sonnet-4"),
      objective: Keyword.get(opts, :objective, "Test objective #{unique_id}"),
      metadata: Keyword.get(opts, :metadata, %{}),
      task_id: Keyword.get(opts, :task_id),
      event_id: Keyword.get(opts, :event_id)
    }

    {:ok, run} = Magus.Agents.create_agent_run(attrs, authorize?: false)
    run
  end

  # ---------------------------------------------------------------------------
  # Feature Usage Domain
  # ---------------------------------------------------------------------------

  @doc """
  Creates a feature usage event directly (not a generator).

  ## Options
    * `:user_id` - User ID (required)
    * `:feature` - Feature name (default: "prompts")
    * `:action` - Action name (default: "create")
    * `:metadata` - Metadata map (default: %{})

  ## Examples

      event = feature_usage_event(user_id: user.id)
      event = feature_usage_event(user_id: user.id, feature: "web_search", action: "execute")
  """
  def feature_usage_event(opts \\ []) do
    user_id = Keyword.fetch!(opts, :user_id)
    feature = Keyword.get(opts, :feature, "prompts")
    action = Keyword.get(opts, :action, "create")
    metadata = Keyword.get(opts, :metadata, %{})

    :ok = Magus.FeatureUsage.track(user_id, feature, action, metadata)
  end

  # ---------------------------------------------------------------------------
  # Helper Functions
  # ---------------------------------------------------------------------------

  @doc """
  Generates a unique email address for testing.
  """
  def unique_email do
    unique_id = "#{System.unique_integer([:positive, :monotonic])}-#{:rand.uniform(1_000_000)}"
    "user-#{unique_id}@test.com"
  end

  @doc """
  Generates a unique string identifier for testing.
  """
  def unique_string(prefix \\ "test") do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  @doc """
  Creates a MessageUsage record for testing usage accounting.

  ## Options

  - `:usage_type` - Usage type atom (default `:response`)
  - `:billable` - Whether the record is billable (default true, via Ash default)
  - Any other MessageUsage attribute can be passed as an option
  """
  def create_usage_record(user, model, opts \\ []) do
    base = %{
      user_id: user.id,
      model_id: model.id,
      model_name: model.name,
      usage_type: Keyword.get(opts, :usage_type, :response),
      prompt_tokens: 100,
      completion_tokens: 100,
      total_tokens: 200
    }

    {:ok, _} =
      Magus.Usage.MessageUsage
      |> Ash.Changeset.for_create(:create, Map.merge(base, Map.new(opts)))
      |> Ash.create(authorize?: false)
  end

  # ---------------------------------------------------------------------------
  # Workspaces Domain
  # ---------------------------------------------------------------------------

  @doc """
  Generates a workspace with the given actor as owner.

  Requires `:actor` option (the user who creates/owns the workspace).

  ## Examples

      user = generate(user())
      workspace = generate(workspace(actor: user))
      workspace = generate(workspace(actor: user, name: "My Team"))
  """
  def workspace(opts \\ []) do
    unique_id = System.unique_integer([:positive, :monotonic])

    changeset_generator(
      Magus.Workspaces.Workspace,
      :create,
      defaults: %{
        name: Keyword.get(opts, :name, "Test Workspace #{unique_id}"),
        slug: Keyword.get(opts, :slug, "test-workspace-#{unique_id}")
      },
      overrides: Keyword.get(opts, :overrides, %{}),
      actor: Keyword.fetch!(opts, :actor)
    )
  end

  @doc """
  Creates a workspace membership directly (not a generator).

  Adds an existing user as a member or admin of an existing workspace. The
  workspace's creator is already an admin via `CreateOwnerMember`; use this
  helper to add additional members for cross-actor access tests.

  ## Options
    * `:user_id` - User to add as member (required)
    * `:workspace_id` - Workspace to join (required)
    * `:role` - `:member` (default) or `:admin`
    * `:invite_email` - Email recorded on the membership (default: derived
      from the user record)

  ## Examples

      workspace_member(user_id: user.id, workspace_id: ws.id)
      workspace_member(user_id: user.id, workspace_id: ws.id, role: :admin)
  """
  def workspace_member(opts \\ []) do
    user_id = Keyword.fetch!(opts, :user_id)
    workspace_id = Keyword.fetch!(opts, :workspace_id)
    role = Keyword.get(opts, :role, :member)

    action =
      case role do
        :admin -> :create_admin
        :member -> :create_member
      end

    invite_email =
      Keyword.get_lazy(opts, :invite_email, fn ->
        {:ok, user} = Magus.Accounts.get_user(user_id, authorize?: false)
        to_string(user.email)
      end)

    Magus.Workspaces.WorkspaceMember
    |> Ash.Changeset.for_create(
      action,
      %{user_id: user_id, workspace_id: workspace_id, invite_email: invite_email},
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  # ---------------------------------------------------------------------------
  # Brain Domain
  # ---------------------------------------------------------------------------

  @doc """
  Generates a brain owned by the given user.

  ## Options
    * `:user_id` - The user who owns the brain (required). Becomes the actor
      for the create action, which sets `user_id` automatically.
    * `:title` - Brain title (default: auto-generated)
    * `:workspace_id` - Workspace the brain lives in (default: nil = personal)

  ## Examples

      brain = generate(brain(user_id: user.id))
      ws_brain = generate(brain(user_id: user.id, workspace_id: ws.id))
  """
  def brain(opts \\ []) do
    user_id = Keyword.fetch!(opts, :user_id)
    unique_id = System.unique_integer([:positive])
    {:ok, owner} = Magus.Accounts.get_user(user_id, authorize?: false)

    changeset_generator(
      Magus.Brain.BrainResource,
      :create,
      defaults: %{
        title: Keyword.get(opts, :title, "Test Brain #{unique_id}"),
        workspace_id: Keyword.get(opts, :workspace_id)
      },
      actor: owner
    )
  end

  @doc """
  Creates a brain page with markdown `body` (not a generator).

  ## Options
    * `:brain_id` - The brain the page belongs to (required)
    * `:user_id` - User who owns the brain (required; used as actor)
    * `:title` - Page title (default: auto-generated)
    * `:content` - Markdown body (default: "" = empty page)

  ## Examples

      page = brain_page(brain_id: brain.id, user_id: user.id)
      page = brain_page(brain_id: brain.id, user_id: user.id, content: "Daniel works on X")
  """
  def brain_page(opts \\ []) do
    brain_id = Keyword.fetch!(opts, :brain_id)
    user_id = Keyword.fetch!(opts, :user_id)
    unique_id = System.unique_integer([:positive])
    title = Keyword.get(opts, :title, "Test Page #{unique_id}")
    body = Keyword.get(opts, :content, "")

    {:ok, owner} = Magus.Accounts.get_user(user_id, authorize?: false)
    {:ok, page} = Magus.Brain.create_page(brain_id, %{title: title}, actor: owner)

    if body != "" do
      replace_page_body(page, body, owner)
    else
      page
    end
  end

  @doc """
  Replaces a brain page's markdown body. Used by tests that change a
  page's text between extraction runs. (Formerly `replace_page_blocks`;
  renamed because the model is markdown, not blocks.)
  """
  def replace_page_body(page, body, owner) do
    {:ok, current} = Magus.Brain.get_page(page.id, actor: owner)

    {:ok, updated} =
      Magus.Brain.update_page_body(
        current,
        %{body: body, base_version: current.lock_version},
        actor: owner
      )

    updated
  end

  @doc """
  Creates an ingested brain Source directly (not a generator).

  ## Options
    * `:brain_id` - required
    * `:user_id` - required (actor)
    * `:url` - source URL (default: auto-generated)
    * `:title` - default auto-generated
    * `:content` - ingested_content (default: "" leaves status :pending)
  """
  def brain_source(opts \\ []) do
    brain_id = Keyword.fetch!(opts, :brain_id)
    _user_id = Keyword.fetch!(opts, :user_id)
    unique_id = System.unique_integer([:positive])
    url = Keyword.get(opts, :url, "https://example.com/#{unique_id}")
    title = Keyword.get(opts, :title, "Source #{unique_id}")
    content = Keyword.get(opts, :content, "")

    {:ok, source} =
      Magus.Brain.Source
      |> Ash.Changeset.for_create(:create, %{
        brain_id: brain_id,
        url: url,
        title: title,
        source_type: :web
      })
      |> Ash.create(authorize?: false)

    if content != "" do
      {:ok, ingested} =
        source
        |> Ash.Changeset.for_update(:ingest, %{
          ingested_content: content,
          ingest_status: :ingested,
          ingested_at: DateTime.utc_now()
        })
        |> Ash.update(authorize?: false)

      ingested
    else
      source
    end
  end

  # ---------------------------------------------------------------------------
  # MCP Domain
  # ---------------------------------------------------------------------------

  @doc """
  Generates an MCP server. Pass `:actor` (owner). Optional `:workspace_id`,
  `:handle`, `:url`, `:auth_type`, `:transport`.
  """
  def mcp_server(opts \\ []) do
    unique_id = System.unique_integer([:positive])
    actor = Keyword.fetch!(opts, :actor)

    changeset_generator(
      Magus.MCP.Server,
      :create,
      defaults: %{
        name: Keyword.get(opts, :name, "Test MCP #{unique_id}"),
        handle: Keyword.get(opts, :handle, "mcp_#{unique_id}"),
        url: Keyword.get(opts, :url, "https://93.184.216.34"),
        transport: Keyword.get(opts, :transport, :streamable_http),
        auth_type: Keyword.get(opts, :auth_type, :none),
        workspace_id: Keyword.get(opts, :workspace_id)
      },
      actor: actor
    )
  end
end
