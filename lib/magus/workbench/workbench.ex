defmodule Magus.Workbench do
  @moduledoc """
  Domain for Workbench UI state: tab sessions per user per workspace.
  """
  use Ash.Domain, otp_app: :magus, extensions: [AshTypescript.Rpc]

  typescript_rpc do
    resource Magus.Workbench.TabSession do
      rpc_action :get_tab_session, :for_user_workspace
      rpc_action :get_or_create_tab_session, :get_or_create
      rpc_action :set_tab_session_mode, :set_mode
      rpc_action :set_tab_session_nav_filter, :set_nav_filter
      rpc_action :open_workbench_tab, :open_tab
      rpc_action :activate_workbench_tab, :activate_tab
      rpc_action :close_workbench_tab, :close_tab
      rpc_action :set_workbench_companion, :set_companion
      rpc_action :reorder_workbench_tabs, :reorder_tabs
      rpc_action :replace_workbench_tabs, :replace_tabs
      rpc_action :update_tab_primary, :update_primary
    end
  end

  resources do
    resource Magus.Workbench.TabSession do
      define :get_tab_session,
        action: :for_user_workspace,
        args: [:workspace_id]

      define :get_or_create_tab_session,
        action: :get_or_create,
        args: [:user_id, :workspace_id]

      define :set_tab_session_mode, action: :set_mode, args: [:mode]
      define :set_tab_session_nav_filter, action: :set_nav_filter, args: [:nav_filter]

      define :open_workbench_tab, action: :open_tab, args: [:primary]
      define :activate_workbench_tab, action: :activate_tab, args: [:tab_id]
      define :close_workbench_tab, action: :close_tab, args: [:tab_id]
      define :set_workbench_companion, action: :set_companion, args: [:tab_id, :companion]
      define :reorder_workbench_tabs, action: :reorder_tabs, args: [:order]
      define :replace_workbench_tabs, action: :replace_tabs, args: [:tabs, :active_tab_id]
      define :update_tab_primary, action: :update_primary, args: [:tab_id, :primary]
    end
  end

  @doc """
  Drop tabs whose underlying resource doesn't belong to `workspace_id`,
  resetting `active_tab_id` if it pointed at one of the dropped tabs.

  Personal mode is `workspace_id == nil`: only tabs whose resource has
  `workspace_id == nil` are kept.

  Returns `{:ok, tab_session}` (with the original session if nothing was
  dropped, or the persisted one otherwise) or `{:error, reason}` if the
  cleanup update fails.
  """
  @spec scope_tabs_to_workspace(map(), String.t() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def scope_tabs_to_workspace(tab_session, workspace_id, opts) do
    actor = Keyword.fetch!(opts, :actor)
    tabs = tab_session.tabs || []

    {kept, dropped} =
      Enum.split_with(tabs, &tab_in_workspace?(&1, workspace_id, actor))

    cond do
      dropped == [] ->
        {:ok, tab_session}

      true ->
        kept_ids = MapSet.new(kept, & &1["id"])

        active_tab_id =
          cond do
            tab_session.active_tab_id && MapSet.member?(kept_ids, tab_session.active_tab_id) ->
              tab_session.active_tab_id

            kept == [] ->
              nil

            true ->
              hd(kept)["id"]
          end

        replace_workbench_tabs(tab_session, kept, active_tab_id, actor: actor)
    end
  end

  # Synthetic "new chat" tab — implicitly belongs to whichever workspace the
  # user is currently in until the conversation is actually created.
  defp tab_in_workspace?(
         %{"primary" => %{"type" => "conversation", "id" => "new"}},
         _ws_id,
         _actor
       ),
       do: true

  defp tab_in_workspace?(%{"primary" => %{"type" => "conversation", "id" => id}}, ws_id, actor) do
    case Magus.Chat.get_conversation(id, actor: actor) do
      {:ok, conv} -> conv.workspace_id == ws_id
      _ -> false
    end
  end

  defp tab_in_workspace?(%{"primary" => %{"type" => "brain_page", "id" => id}}, ws_id, actor) do
    case Magus.Brain.get_page(id, actor: actor, load: [:brain]) do
      {:ok, %{brain: %{workspace_id: brain_ws_id}}} -> brain_ws_id == ws_id
      _ -> false
    end
  end

  defp tab_in_workspace?(%{"primary" => %{"type" => "file", "id" => id}}, ws_id, actor) do
    case Magus.Files.get_file(id, actor: actor) do
      {:ok, file} -> file.workspace_id == ws_id
      _ -> false
    end
  end

  defp tab_in_workspace?(_tab, _ws_id, _actor), do: false
end
