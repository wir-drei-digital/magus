defmodule Magus.Agents.Context.Builder do
  @moduledoc """
  Builds LLM context from conversation history, system prompts, and memory.

  Handles:
  - Building system prompts with mode-specific instructions
  - Requesting memory context via BuildMemoryContext action
  - Building current message content with attachments
  """

  require Logger

  alias Magus.Agents.Actions.BuildMemoryContext
  alias Magus.Agents.Context.AttachedDocumentsContext
  alias Magus.Agents.Context.BrainContext
  alias Magus.Agents.Context.BrainRagContext
  alias Magus.Agents.Context.CompanionPreamble
  alias Magus.Agents.Context.DraftContext
  alias Magus.Agents.Context.JobsContext
  alias Magus.Agents.Context.SectionMarker
  alias Magus.Agents.Context.SuperBrainRagContext
  alias Magus.Agents.Context.SystemPrompts
  alias Magus.Agents.Context.TaskContext
  alias Magus.Agents.Context.RagContext
  alias Magus.Agents.Context.WakeupPreamble
  alias Magus.Agents.Context.WorkspaceContext
  alias Magus.Files.EmbeddingModel

  # The query embedding runs on every message. Bound it tightly so a slow
  # provider degrades to no-RAG-this-turn instead of blocking (and previously
  # crashing) the agent. The pgvector/FTS/DB work in the parallel block is
  # local and fast; this network call is the only real latency source.
  @query_embedding_timeout_ms 3_000

  @doc """
  Builds the complete LLM context including system prompt, conversation history,
  memory context, and current message.
  """
  def build_llm_context(
        conversation,
        message_id,
        text,
        attachments,
        mode,
        model,
        selections \\ %{}
      ) do
    # Use explicit custom_agent if provided in selections, otherwise fall back to conversation's
    agent_config =
      if is_map(selections) && selections[:custom_agent],
        do: selections[:custom_agent],
        else: safe_get(conversation, :custom_agent)

    active_draft_id =
      if is_map(selections), do: selections[:active_draft_id], else: nil

    # Tools from selections enable orchestration_capabilities in SystemPrompts
    tools = if is_map(selections), do: selections[:tools] || [], else: []

    load_skills =
      if tools != [] do
        true
      else
        is_map(model) and Map.get(model, :supports_tools?, false)
      end

    # Compute memory prerequisites before parallel block
    user = conversation.user

    global_enabled =
      user.global_memory_enabled && agent_allows_global_memories?(agent_config)

    # Phase 1: Run all independent DB queries concurrently
    # memory_context only needs user_id, conversation_id, text, global_enabled
    # so it can run in parallel with workspace/jobs/draft
    custom_agent_id =
      if agent_config, do: Map.get(agent_config, :id), else: nil

    isolation_flags =
      Magus.Agents.Tools.ToolBuilder.extract_agent_isolation_flags(agent_config)

    # Brain context from selections (brain pane open)
    brain_context =
      if is_map(selections) && selections[:brain_id] do
        BrainContext.build(
          selections[:brain_id],
          selections[:brain_page_id],
          actor: user,
          workspace_id: safe_get(conversation, :workspace_id)
        )
      end

    # Run all independent DB queries concurrently, including message history
    is_multiplayer = Map.get(conversation, :is_multiplayer, false)
    is_thread = Map.get(conversation, :is_thread, false)

    # Embed the query ONCE and share the vector across every retriever below
    # (memory, file RAG, brain RAG), instead of each making its own redundant
    # network call. Bounded by a short timeout; nil means "no semantic context
    # this turn" (retrievers degrade to skip/FTS), never a crash.
    query_embedding = compute_query_embedding(text)

    [
      workspace_context,
      jobs_context,
      draft_context,
      tasks_context,
      memory_context,
      rag_context,
      brain_rag_context,
      super_brain_context,
      attached_documents_context,
      history
    ] =
      Task.await_many(
        [
          Task.async(fn -> WorkspaceContext.build(conversation.id, actor: user) end),
          Task.async(fn -> JobsContext.build(conversation.id, actor: user) end),
          Task.async(fn -> DraftContext.build(conversation.id, active_draft_id, actor: user) end),
          Task.async(fn -> TaskContext.build(conversation.id, actor: user) end),
          Task.async(fn ->
            request_memory_context(
              conversation.user_id,
              conversation.id,
              text,
              global_enabled,
              custom_agent_id,
              query_embedding
            )
          end),
          Task.async(fn ->
            RagContext.build(%{
              query: text,
              query_embedding: query_embedding,
              user: user,
              conversation_id: conversation.id,
              folder_id: safe_get(conversation, :folder_id),
              workspace_id: safe_get(conversation, :workspace_id),
              custom_agent_id: custom_agent_id,
              can_access_global_files: isolation_flags.can_access_global_files,
              can_access_knowledge: isolation_flags.can_access_knowledge
            })
          end),
          Task.async(fn ->
            BrainRagContext.build(%{
              query: text,
              query_embedding: query_embedding,
              user: user,
              brain_id: if(is_map(selections), do: selections[:brain_id]),
              workspace_id: safe_get(conversation, :workspace_id),
              custom_agent_id: custom_agent_id
            })
          end),
          Task.async(fn ->
            SuperBrainRagContext.build(%{
              query: text,
              user: user,
              workspace_id: safe_get(conversation, :workspace_id)
            })
          end),
          Task.async(fn ->
            case agent_config do
              %Magus.Agents.CustomAgent{} = a ->
                a
                |> Ash.load!([attachments: [file: [:chunks]]], authorize?: false)
                |> AttachedDocumentsContext.build()

              _ ->
                ""
            end
          end),
          Task.async(fn ->
            if is_thread do
              Magus.Chat.build_thread_message_history!(
                conversation.id,
                message_id,
                is_multiplayer
              )
            else
              Magus.Chat.build_message_history!(
                conversation.id,
                message_id,
                is_multiplayer
              )
            end
          end)
        ],
        15_000
      )

    # System prompt (pure composition, no DB)
    base_system_prompt =
      SystemPrompts.build(
        mode: mode,
        conversation: conversation,
        custom_agent: agent_config,
        system_prompt: safe_get(conversation, :active_system_prompt),
        user: user,
        load_skills: load_skills,
        workspace_context: workspace_context,
        draft_context: draft_context,
        brain_context: brain_context,
        jobs_context: jobs_context,
        tasks_context: tasks_context,
        tools: tools,
        attached_documents_context: attached_documents_context
      )

    # For autonomous runs (heartbeat / manual trigger), prepend a wakeup preamble
    # that orients the agent: time, default interval, last wake-up, inbox/tasks
    # snapshot, and the autonomy tools available. Returns "" for other sources.
    wakeup_source = if is_map(selections), do: selections[:source], else: nil

    wakeup_preamble =
      WakeupPreamble.build(%{
        custom_agent: agent_config,
        source: wakeup_source || :user_message,
        user: user
      })

    # Companion preamble identifies the file/brain page this conversation is
    # paired with, so the agent treats it as the implicit subject and knows
    # which tool to call to read it. Returns "" for non-companion conversations.
    companion_preamble =
      CompanionPreamble.build(%{
        conversation_id: conversation.id,
        user: user,
        workspace_id: safe_get(conversation, :workspace_id)
      })

    # Order is intentional: wakeup orients an autonomous agent in time;
    # companion orients in subject; base persona/skills come last. The base
    # system prompt is already section-marked (SystemPrompts.compose); the two
    # preambles get their own markers here so ContextReport attributes them.
    system_prompt =
      [
        SectionMarker.wrap(:wakeup, wakeup_preamble),
        SectionMarker.wrap(:companion, companion_preamble),
        base_system_prompt
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n\n---\n\n")

    # Append memory, RAG, brain RAG, and super brain context to system prompt
    system_prompt =
      system_prompt
      |> append_context(:memory, memory_context)
      |> append_context(:files_rag, rag_context)
      |> append_context(:brain, brain_rag_context)
      |> append_context(:super_brain, super_brain_context)

    # Contextual just-in-time hint: nudge the agent to tool_search when the
    # incoming message matches a tool that is hidden behind search this turn.
    # Actor-scoped so MCP tools (gated on a concrete `%User{}`) also surface in
    # the nudge; ActorContext.from/1 loads the actor if `user` is NotLoaded.
    hint_actor_context =
      Magus.Agents.Tools.Search.ActorContext.from(%{
        user: user,
        user_id: conversation.user_id,
        conversation_id: conversation.id
      })

    system_prompt =
      append_context(
        system_prompt,
        :tool_hint,
        Magus.Agents.Tools.Catalog.hint_for(text, tools, hint_actor_context)
      )

    # Build current message content (with selection context if present)
    draft_selection = if is_map(selections), do: selections[:draft], else: nil
    brain_selection = if is_map(selections), do: selections[:brain], else: nil
    pdf_selection = if is_map(selections), do: selections[:pdf], else: nil
    service_selection = if is_map(selections), do: selections[:service], else: nil
    message_selections = if is_map(selections), do: selections[:message_selections], else: nil

    # The live clock lives here (on the current turn), NOT in the system prompt:
    # the system prompt must stay byte-identical across turns so its prefix hash
    # stays warm for prompt caching. Only the current turn carries the timestamp;
    # message history is never touched.
    current_content =
      prepend_message_selections(text, message_selections)
      |> prepend_draft_selection(draft_selection)
      |> prepend_brain_selection(brain_selection)
      |> prepend_pdf_selection_text(pdf_selection)
      |> prepend_service_selection_text(service_selection)
      |> prepend_current_time(user)
      |> build_current_message_content(attachments)
      |> maybe_append_pdf_screenshot(pdf_selection)
      |> maybe_append_screenshot(service_selection)

    # Return {system_prompt, messages} — no ReqLLM.Context wrapping
    {system_prompt, history ++ [ReqLLM.Context.user(current_content)]}
  end

  @doc """
  Extracts the last user message text from LLM context.
  """
  def extract_last_user_message(nil), do: ""

  def extract_last_user_message(context) do
    context
    |> Enum.reverse()
    |> Enum.find_value("", fn msg ->
      case msg do
        %{role: :user, content: content} when is_binary(content) ->
          content

        %{role: :user, content: content} when is_list(content) ->
          # Content may be a list of parts (text, images, etc.)
          Enum.find_value(content, "", fn
            # A ContentPart struct is also a map, so this clause matches both
            # plain maps and %ReqLLM.Message.ContentPart{} parts.
            %{type: :text, text: text} -> text
            _ -> nil
          end)

        _ ->
          nil
      end
    end)
  end

  @doc """
  Builds multi-part message content from text and attachment IDs.

  Returns a list of `ReqLLM.Message.ContentPart` structs with actual image
  binary data (not text placeholders), preserving images for vision-capable models.
  """
  def build_current_message_content(text, nil), do: build_current_message_content(text, [])

  def build_current_message_content(text, []) do
    [ReqLLM.Message.ContentPart.text(text)]
  end

  def build_current_message_content(text, attachment_ids) do
    text_part = ReqLLM.Message.ContentPart.text(text)

    content_parts =
      Magus.Files.load_llm_content_parts!(attachment_ids,
        actor: %Magus.Agents.Support.AiAgent{}
      )

    attachment_parts =
      Enum.map(content_parts, fn
        %{type: :image, media_type: mime, data: base64_data} ->
          binary_data = Base.decode64!(base64_data)
          ReqLLM.Message.ContentPart.image(binary_data, mime)

        %{type: :text, text: t} ->
          ReqLLM.Message.ContentPart.text(t)

        other ->
          other
      end)

    [text_part | attachment_parts]
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  # Request memory context by calling BuildMemoryContext action directly
  defp request_memory_context(
         user_id,
         conversation_id,
         query_text,
         global_enabled,
         custom_agent_id,
         query_embedding
       ) do
    case BuildMemoryContext.build(%{
           user_id: to_string(user_id),
           conversation_id: to_string(conversation_id),
           query_text: query_text,
           query_embedding: query_embedding,
           global_enabled: global_enabled,
           custom_agent_id: if(custom_agent_id, do: to_string(custom_agent_id))
         }) do
      {:ok, context} -> context.formatted || ""
      {:error, _} -> ""
    end
  rescue
    e ->
      Logger.warning("Exception requesting memory context: #{Exception.message(e)}")
      ""
  end

  # Embed the query once for all retrievers, with a short timeout so a slow
  # provider degrades to no-semantic-context this turn instead of blocking.
  # Returns the vector, or nil (retrievers treat nil as "skip semantic / FTS").
  defp compute_query_embedding(text) when is_binary(text) and byte_size(text) > 0 do
    case EmbeddingModel.embed(text, receive_timeout: @query_embedding_timeout_ms) do
      {:ok, embedding} ->
        embedding

      {:error, reason} ->
        Logger.warning("Context query embedding failed/timed out: #{inspect(reason)}")
        nil
    end
  end

  defp compute_query_embedding(_), do: nil

  defp agent_allows_global_memories?(%{can_read_global_memories: false}), do: false
  defp agent_allows_global_memories?(_), do: true

  @doc """
  Prefix a single concise current-time line to the current user turn text.

  The line carries the user's local time, the equivalent UTC time, and the
  timezone name, e.g.:

      [Current time: 2026-06-16 14:32 CEST (UTC 12:32). Timezone: Europe/Zurich.]

  This is the ONLY place the live clock enters the prompt — the system prompt is
  kept byte-stable for caching, so the model stays time-aware via the current turn.

  Timezone handling mirrors `SystemPrompts.time_context_for_timezone/1`: a nil or
  invalid timezone falls back to UTC.

  Public for unit testing; called from `build_llm_context/7`.
  """
  @spec prepend_current_time(String.t(), map() | nil) :: String.t()
  def prepend_current_time(text, user) do
    tz = user_timezone(user)
    utc_now = DateTime.utc_now()

    utc_label = Calendar.strftime(utc_now, "%H:%M")

    {local_label, tz_name} =
      case DateTime.shift_zone(utc_now, tz) do
        {:ok, shifted} ->
          {Calendar.strftime(shifted, "%Y-%m-%d %H:%M %Z"), tz}

        _ ->
          # Invalid/unknown timezone — fall back to UTC.
          {Calendar.strftime(utc_now, "%Y-%m-%d %H:%M UTC"), "UTC"}
      end

    "[Current time: #{local_label} (UTC #{utc_label}). Timezone: #{tz_name}.]\n\n#{text}"
  end

  defp user_timezone(%{timezone: tz}) when is_binary(tz) and tz != "", do: tz
  defp user_timezone(_), do: "UTC"

  defp prepend_message_selections(text, nil), do: text
  defp prepend_message_selections(text, []), do: text

  defp prepend_message_selections(text, selections) when is_list(selections) do
    blocks =
      selections
      |> Enum.filter(fn sel ->
        selected_text = sel["text"] || sel[:text] || ""
        selected_text != ""
      end)
      |> Enum.map(fn sel ->
        selected_text = sel["text"] || sel[:text] || ""
        role = sel["role"] || sel[:role] || "agent"
        role_label = if role == "user", do: "your earlier message", else: "an earlier response"

        """
        [Selected text from #{role_label}:
        ---
        #{selected_text}
        ---]\
        """
      end)

    case blocks do
      [] -> text
      _ -> Enum.join(blocks, "\n\n") <> "\n\n" <> text
    end
  end

  defp prepend_message_selections(text, _), do: text

  defp prepend_draft_selection(text, nil), do: text

  defp prepend_draft_selection(text, selection) when is_map(selection) do
    selected_text = selection["text"] || selection[:text] || ""
    hint_line = selection["hint_line"] || selection[:hint_line]
    title = selection["draft_title"] || selection[:draft_title] || "Draft"

    if selected_text != "" do
      """
      [Draft selection from "#{title}" (near line #{hint_line}):
      ---
      #{selected_text}
      ---]

      #{text}\
      """
    else
      text
    end
  end

  defp prepend_draft_selection(text, _), do: text

  defp prepend_brain_selection(content, nil), do: content

  defp prepend_brain_selection(content, %{"text" => text} = selection) do
    page_title = selection["page_title"] || "brain page"
    "[Brain selection from \"#{page_title}\":\n---\n#{text}\n---]\n\n#{content}"
  end

  defp prepend_brain_selection(content, _), do: content

  defp prepend_pdf_selection_text(text, nil), do: text

  defp prepend_pdf_selection_text(text, selection) when is_map(selection) do
    page = selection["page"] || selection[:page]
    filename = selection["filename"] || selection[:filename] || "PDF"
    extracted = selection["text"] || selection[:text] || ""

    header =
      "[The user selected a region from \"#{filename}\" (page #{page}). Screenshot attached as image."

    header = if extracted != "", do: header <> " Extracted text: #{extracted}", else: header
    header = header <> "]"

    "#{header}\n\n#{text}"
  end

  defp prepend_pdf_selection_text(text, _), do: text

  defp maybe_append_pdf_screenshot(content_parts, nil), do: content_parts

  defp maybe_append_pdf_screenshot(content_parts, selection) when is_map(selection) do
    case selection["image"] || selection[:image] do
      "data:image/" <> _ = data_url ->
        with [_header, base64_data] <- String.split(data_url, ",", parts: 2),
             {:ok, image_binary} <- Base.decode64(base64_data) do
          mime = if String.contains?(data_url, "jpeg"), do: "image/jpeg", else: "image/png"
          image_part = ReqLLM.Message.ContentPart.image(image_binary, mime)
          content_parts ++ [image_part]
        else
          _ ->
            Logger.warning("Invalid base64 in PDF selection image, skipping")
            content_parts
        end

      _ ->
        content_parts
    end
  end

  defp maybe_append_pdf_screenshot(content_parts, _), do: content_parts

  defp prepend_service_selection_text(text, nil), do: text

  defp prepend_service_selection_text(text, selection) when is_map(selection) do
    service_name = selection["service_name"] || selection[:service_name] || "Service"

    "[The user captured a screenshot from the sandbox service \"#{service_name}\". Screenshot attached as image.]\n\n#{text}"
  end

  defp prepend_service_selection_text(text, _), do: text

  defp maybe_append_screenshot(content_parts, nil), do: content_parts

  defp maybe_append_screenshot(content_parts, selection) when is_map(selection) do
    case selection["image"] || selection[:image] do
      "data:image/" <> _ = data_url ->
        with [_header, base64_data] <- String.split(data_url, ",", parts: 2),
             {:ok, image_binary} <- Base.decode64(base64_data) do
          mime = if String.contains?(data_url, "jpeg"), do: "image/jpeg", else: "image/png"
          image_part = ReqLLM.Message.ContentPart.image(image_binary, mime)
          content_parts ++ [image_part]
        else
          _ ->
            Logger.warning("Invalid base64 in service selection image, skipping")
            content_parts
        end

      _ ->
        content_parts
    end
  end

  defp maybe_append_screenshot(content_parts, _), do: content_parts

  defp append_context(system_prompt, _category, body) when body in [nil, ""], do: system_prompt

  # Use the same section separator the base system prompt joins with
  # (SystemPrompts joins top-level sections with "\n\n---\n\n"). Appending
  # dynamic context (memory/RAG/brain/super-brain/tool hints) with a bare
  # "\n\n" glued it onto the previous section, so ContextReport — which splits
  # on "\n\n---\n\n" — mis-counted those tokens under whatever heading came
  # before (e.g. lumping retrieved context into "Time"/"## Scheduling"). The
  # `category` marker lets ContextReport attribute each appended block exactly.
  defp append_context(system_prompt, category, body),
    do: system_prompt <> "\n\n---\n\n" <> SectionMarker.wrap(category, body)

  # Safe accessor that returns nil for Ash.NotLoaded values
  defp safe_get(map, field) do
    case Map.get(map, field) do
      %Ash.NotLoaded{} -> nil
      value -> value
    end
  end
end
