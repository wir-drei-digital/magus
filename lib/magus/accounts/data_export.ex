defmodule Magus.Accounts.DataExport do
  @moduledoc """
  Builds a serializable snapshot of everything Magus has stored for a
  given user. Pure function: no IO besides authorized DB reads, no
  network calls. Intended to be encoded to JSON and streamed to the
  user as a download from `MagusWeb.SettingsController.export_data/2`.

  v1 scope (per spec 2026-04-26): profile, conversations the user owns,
  folders, memories, brains, custom_agents (definitions only, no secret
  values), prompts, favorites, drafts. Excluded: file binaries, secret
  values, internal Stripe identifiers, deleted-record tombstones,
  embeddings, lock_version, and resources owned by other users that the
  actor only has transient access to.
  """

  @schema_version 1

  require Ash.Query

  alias Magus.Accounts.User

  @spec build(User.t()) :: map()
  def build(%User{} = user) do
    %{
      schema_version: @schema_version,
      exported_at: DateTime.utc_now(),
      profile: profile(user),
      conversations: conversations(user),
      folders: folders(user),
      memories: memories(user),
      brains: brains(user),
      custom_agents: custom_agents(user),
      prompts: prompts(user),
      favorites: favorites(user),
      drafts: drafts(user)
    }
  end

  defp profile(user) do
    %{
      email: to_string(user.email),
      display_name: user.display_name,
      language: user.language,
      timezone: user.timezone,
      accepted_terms: user.accepted_terms,
      ui_preferences: user.ui_preferences,
      selected_model_id: user.selected_model_id,
      selected_image_model_id: user.selected_image_model_id,
      selected_video_model_id: user.selected_video_model_id
    }
  end

  defp conversations(user) do
    Magus.Chat.Conversation
    |> Ash.Query.filter(user_id == ^user.id and is_nil(deleted_at))
    |> Ash.Query.load(:messages)
    |> Ash.read!(authorize?: false)
    |> Enum.map(&serialize_conversation/1)
  end

  defp serialize_conversation(c) do
    %{
      id: c.id,
      title: c.title,
      chat_mode: c.chat_mode,
      folder_id: c.folder_id,
      sampling_settings: c.sampling_settings,
      system_prompt_id: c.system_prompt_id,
      inserted_at: c.inserted_at,
      messages: Enum.map(c.messages || [], &serialize_message/1)
    }
  end

  # Export ALL messages including disabled/redacted ones. The right-to-data
  # guarantee of this feature overrides the per-message UI hide toggle: the
  # data IS in our system, so it MUST appear in the user's export.
  defp serialize_message(m) do
    %{
      id: m.id,
      role: m.role,
      text: m.text,
      message_type: m.message_type,
      status: m.status,
      citations: m.citations,
      reasoning_details: m.reasoning_details,
      tool_call_data: m.tool_call_data,
      inserted_at: m.inserted_at
    }
  end

  defp folders(user) do
    Magus.Chat.Folder
    |> Ash.Query.filter(user_id == ^user.id)
    |> Ash.read!(authorize?: false)
    |> Enum.map(fn f ->
      %{
        id: f.id,
        name: f.name,
        parent_id: f.parent_id,
        position: f.position,
        inserted_at: f.inserted_at
      }
    end)
  end

  defp memories(user) do
    Magus.Memory.Memory
    |> Ash.Query.filter(user_id == ^user.id)
    |> Ash.read!(authorize?: false)
    |> Enum.map(fn m ->
      %{
        id: m.id,
        scope: m.scope,
        name: m.name,
        summary: m.summary,
        content: m.content,
        kind: m.kind,
        conversation_id: m.conversation_id,
        custom_agent_id: m.custom_agent_id,
        workspace_id: m.workspace_id,
        inserted_at: m.inserted_at,
        updated_at: m.updated_at
      }
    end)
  end

  # Phase B/C internal frontmatter cache keys. They live in the persisted
  # `frontmatter` map alongside user-authored YAML but represent parser
  # state (built-at timestamps, sentinel flags), not user data — strip
  # them before handing the export to the user.
  @frontmatter_sentinel_keys ~w(
    _no_frontmatter
    _parse_error
    _links_built_at
    _sources_built_at
    _tags_built_at
  )

  defp brains(user) do
    Magus.Brain.BrainResource
    |> Ash.Query.filter(user_id == ^user.id and is_archived == false)
    |> Ash.Query.load(:pages)
    |> Ash.read!(authorize?: false)
    |> Enum.map(&serialize_brain/1)
  end

  defp serialize_brain(b) do
    %{
      id: b.id,
      title: b.title,
      slug: b.slug,
      description: b.description,
      icon: b.icon,
      color: b.color,
      is_archived: b.is_archived,
      workspace_id: b.workspace_id,
      inserted_at: b.inserted_at,
      updated_at: b.updated_at,
      pages: Enum.map(b.pages || [], &serialize_page/1)
    }
  end

  defp serialize_page(p) do
    %{
      id: p.id,
      title: p.title,
      slug: p.slug,
      icon: p.icon,
      parent_page_id: p.parent_page_id,
      depth: p.depth,
      position: p.position,
      body: p.body,
      frontmatter: clean_frontmatter(p.frontmatter),
      tags: load_page_tags(p.id),
      wikilinks: load_page_wikilinks(p.id),
      inserted_at: p.inserted_at,
      updated_at: p.updated_at
    }
  end

  defp clean_frontmatter(fm) when is_map(fm), do: Map.drop(fm, @frontmatter_sentinel_keys)
  defp clean_frontmatter(_), do: %{}

  defp load_page_tags(page_id) do
    Magus.Brain.PageTag
    |> Ash.Query.filter(page_id == ^page_id)
    |> Ash.Query.sort(tag: :asc)
    |> Ash.read!(authorize?: false)
    |> Enum.map(fn t -> %{tag: t.tag, source: t.source} end)
  end

  # Outgoing wikilinks as target titles captured at link time, deduped
  # while preserving first-occurrence order. The export reflects what the
  # user wrote: the `[[Target]]` text in their body, not the rename-drift-
  # corrected current title of the resolved page.
  defp load_page_wikilinks(page_id) do
    Magus.Brain.PageLink
    |> Ash.Query.filter(source_page_id == ^page_id)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.target_title_at_link_time)
    |> Enum.uniq()
  end

  defp custom_agents(user) do
    Magus.Agents.CustomAgent
    |> Ash.Query.filter(user_id == ^user.id)
    |> Ash.read!(authorize?: false)
    |> Enum.map(fn a ->
      %{
        id: a.id,
        name: a.name,
        instructions: a.instructions,
        model_id: Map.get(a, :model_id),
        workspace_id: a.workspace_id,
        inserted_at: a.inserted_at,
        secret_names: load_secret_names(a.id)
      }
    end)
  end

  # Listed by name only — secret VALUES are intentionally excluded from the export.
  defp load_secret_names(custom_agent_id) do
    Magus.Agents.AgentSecret
    |> Ash.Query.filter(custom_agent_id == ^custom_agent_id)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.key)
  rescue
    _ -> []
  end

  defp prompts(user) do
    Magus.Library.Prompt
    |> Ash.Query.filter(user_id == ^user.id)
    |> Ash.Query.load([:tags])
    |> Ash.read!(authorize?: false)
    |> Enum.map(fn p ->
      %{
        id: p.id,
        name: p.name,
        content: p.content,
        type: p.type,
        model_id: Map.get(p, :model_id),
        chat_mode: Map.get(p, :chat_mode),
        is_public: Map.get(p, :is_public),
        inserted_at: p.inserted_at,
        tags: Enum.map(p.tags || [], & &1.name)
      }
    end)
  end

  defp favorites(user) do
    conversation_favorite_ids =
      Magus.Chat.ConversationFavorite
      |> Ash.Query.filter(user_id == ^user.id)
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.conversation_id)

    prompt_favorite_ids =
      Magus.Library.PromptFavorite
      |> Ash.Query.filter(user_id == ^user.id)
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.prompt_id)

    %{
      conversations: conversation_favorite_ids,
      prompts: prompt_favorite_ids
    }
  end

  defp drafts(user) do
    Magus.Drafts.Draft
    |> Ash.Query.filter(user_id == ^user.id)
    |> Ash.read!(authorize?: false)
    |> Enum.map(fn d ->
      %{
        id: d.id,
        conversation_id: d.conversation_id,
        title: d.title,
        content: d.content,
        inserted_at: d.inserted_at,
        updated_at: d.updated_at
      }
    end)
  end
end
