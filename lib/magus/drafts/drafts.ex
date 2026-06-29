defmodule Magus.Drafts do
  @moduledoc """
  Drafts domain: per-conversation draft message storage. Drafts inherit access
  from their parent conversation and carry no own workspace or grants.
  """

  use Ash.Domain,
    otp_app: :magus,
    extensions: [AshPaperTrail.Domain, AshTypescript.Rpc]

  require Ash.Query

  paper_trail do
    include_versions? true
  end

  # Draft companion exposure for the SvelteKit workbench: listing, TipTap
  # editing (PM JSON writes; version increments server-side), rename, delete.
  typescript_rpc do
    resource Magus.Drafts.Draft do
      rpc_action :conversation_drafts, :list_by_conversation
      rpc_action :update_draft_content, :update_content_json
      rpc_action :rename_draft, :update_title
      rpc_action :delete_draft, :destroy
      rpc_action :export_draft, :export
      rpc_action :draft_versions, :list_versions
      rpc_action :restore_draft_version, :restore_version

      rpc_action :get_draft, :read do
        get_by [:id]
      end
    end
  end

  resources do
    resource Magus.Drafts.Draft do
      define :create_draft,
        action: :create,
        args: [:conversation_id, :title, :content, {:optional, :user_id}]

      define :update_draft_content, action: :update_content, args: [:content]
      define :update_draft_content_json, action: :update_content_json, args: [:content_json]
      define :update_draft_title, action: :update_title, args: [:title]

      define :replace_draft_text,
        action: :replace_text,
        args: [:old_text, :new_text, {:optional, :hint_line}]

      define :get_draft, action: :read, get_by: [:id]

      define :list_drafts_for_conversation,
        action: :list_by_conversation,
        args: [:conversation_id]

      define :destroy_draft, action: :destroy

      define :request_draft_review,
        action: :request_review,
        args: [:draft_id, :conversation_id]

      define :export_draft,
        action: :export,
        args: [:draft_id, :conversation_id, :export_format]

      define :restore_draft_version, action: :restore_version, args: [:version_id]
    end

    resource Magus.Drafts.Draft.Version
  end

  @doc """
  Returns the most recently updated draft for a conversation, or nil if none exists.
  Backward-compatible wrapper around `list_drafts_for_conversation/2`.
  """
  def get_draft_for_conversation(conversation_id, opts \\ []) do
    case list_drafts_for_conversation(conversation_id, opts) do
      {:ok, [draft | _]} -> {:ok, draft}
      {:ok, []} -> {:ok, nil}
      error -> error
    end
  end

  @doc """
  Returns the ID of the active draft for a user in a conversation.

  Checks PaneState to find which draft is active. Falls back to the most
  recently updated draft if none is explicitly set. Returns `nil` if no
  drafts exist.
  """
  def get_active_draft_id(conversation_id, user_id) do
    case list_drafts_for_conversation(conversation_id, actor: %Magus.Agents.Support.AiAgent{}) do
      {:ok, [_ | _] = drafts} ->
        case Magus.Chat.get_pane_state(conversation_id, user_id,
               actor: %Magus.Agents.Support.AiAgent{}
             ) do
          {:ok, %{pane_type: :draft, resource_id: draft_id}} when not is_nil(draft_id) ->
            if Enum.any?(drafts, &(&1.id == draft_id)), do: draft_id, else: hd(drafts).id

          _ ->
            hd(drafts).id
        end

      _ ->
        nil
    end
  end

  @doc """
  Lists paper trail versions for a draft, most recent first.
  """
  def list_draft_versions(draft_id, opts \\ []) do
    Magus.Drafts.Draft.Version
    |> Ash.Query.filter(version_source_id == ^draft_id)
    |> Ash.Query.sort(version_inserted_at: :desc)
    |> Ash.read(opts)
  end
end
