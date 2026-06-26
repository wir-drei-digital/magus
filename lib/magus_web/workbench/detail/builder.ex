defmodule MagusWeb.Workbench.Detail.Builder do
  @moduledoc """
  Builds detail-view specs (the map stored in WorkbenchLive's :detail_view
  socket assign). Each `build_*` function returns a map shaped:

      %{
        type: atom,                                  # :settings, :jobs, etc.
        live_module: module,                         # the live_render target
        live_session: %{required(String.t) => any},  # mount session
        live_id: String.t,                           # live_render id (unique per variant)
        title: String.t,                             # nav-pane title
        sections: [section_spec]                     # DetailNav entries
      }

  Section spec: %{key: atom, label: String.t, icon: String.t | nil, href: String.t, active?: boolean}
  """

  alias MagusWeb.Workbench.Detail.{
    BrainTrashView,
    HistoryView,
    JobsView,
    SearchView,
    SettingsView,
    WorkspaceMembersView,
    WorkspaceSettingsView,
    WorkspaceUsageView
  }

  # Settings -----------------------------------------------------------------

  def build_settings(params, current_user) do
    section = Map.get(params, "section", "profile")
    user_id = current_user.id

    %{
      type: :settings,
      live_module: SettingsView,
      live_session: %{"section" => section, "user_id" => user_id},
      live_id: "detail-settings-#{section}",
      title: "Settings",
      sections: settings_sections(section, current_user)
    }
  end

  # ~p does not support dynamic segment interpolation here; using plain string.
  defp settings_sections(active, _user) do
    [
      %{
        key: :profile,
        label: "Profile",
        icon: "lucide-user",
        href: "/settings",
        active?: active in ["profile", nil]
      },
      %{
        key: :preferences,
        label: "Preferences",
        icon: "lucide-sliders",
        href: "/settings/preferences",
        active?: active == "preferences"
      },
      %{
        key: :storage,
        label: "Storage",
        icon: "lucide-database",
        href: "/settings/storage",
        active?: active == "storage"
      },
      %{
        key: :data,
        label: "My Data",
        icon: "lucide-shield",
        href: "/settings/data",
        active?: active == "data"
      },
      %{
        key: :knowledge,
        label: "Connected Sources",
        icon: "lucide-folder-sync",
        href: "/settings/knowledge",
        active?: active == "knowledge"
      },
      %{
        key: :integrations,
        label: "Integrations",
        icon: "lucide-plug",
        href: "/settings/integrations",
        active?: active == "integrations"
      },
      %{
        key: :subscription,
        label: "Subscription",
        icon: "lucide-credit-card",
        href: "/settings/subscription",
        active?: active == "subscription"
      },
      %{
        key: :usage,
        label: "Usage",
        icon: "lucide-receipt",
        href: "/settings/usage",
        active?: active == "usage"
      }
    ]
  end

  # Workspace settings -------------------------------------------------------

  def build_workspace_settings(slug, current_user) do
    %{
      type: :workspace_settings,
      live_module: WorkspaceSettingsView,
      live_session: %{"slug" => slug, "user_id" => current_user.id},
      live_id: "detail-workspace-settings-#{slug}",
      title: "Workspace",
      sections: workspace_sections(slug, :settings)
    }
  end

  def build_workspace_members(slug, current_user) do
    %{
      type: :workspace_members,
      live_module: WorkspaceMembersView,
      live_session: %{"slug" => slug, "user_id" => current_user.id},
      live_id: "detail-workspace-members-#{slug}",
      title: "Workspace",
      sections: workspace_sections(slug, :members)
    }
  end

  def build_workspace_usage(slug, current_user) do
    %{
      type: :workspace_usage,
      live_module: WorkspaceUsageView,
      live_session: %{"slug" => slug, "user_id" => current_user.id},
      live_id: "detail-workspace-usage-#{slug}",
      title: "Workspace",
      sections: workspace_sections(slug, :usage)
    }
  end

  defp workspace_sections(slug, active) do
    [
      %{
        key: :settings,
        label: "General",
        icon: "lucide-settings",
        href: "/workspaces/#{slug}",
        active?: active == :settings
      },
      %{
        key: :members,
        label: "Members",
        icon: "lucide-users",
        href: "/workspaces/#{slug}/members",
        active?: active == :members
      },
      %{
        key: :usage,
        label: "Usage",
        icon: "lucide-bar-chart-3",
        href: "/workspaces/#{slug}/usage",
        active?: active == :usage
      }
    ]
  end

  # Jobs ---------------------------------------------------------------------

  def build_jobs(params, current_user) do
    job_id = Map.get(params, "id")

    %{
      type: :jobs,
      live_module: JobsView,
      live_session: %{"user_id" => current_user.id, "job_id" => job_id},
      live_id: "detail-jobs-#{job_id || "index"}",
      title: "Jobs",
      sections: []
    }
  end

  # Brain trash --------------------------------------------------------------

  def build_brain_trash(_params, current_user, workspace_id) do
    %{
      type: :brain_trash,
      live_module: BrainTrashView,
      live_session: %{
        "user_id" => current_user.id,
        "workspace_id" => workspace_id
      },
      live_id: "detail-brain-trash-#{workspace_id || "personal"}",
      title: "Brain trash",
      sections: []
    }
  end

  # History ------------------------------------------------------------------

  def build_history(params, current_user, workspace_id) do
    tab = parse_history_tab(Map.get(params, "tab"))

    %{
      type: :history,
      live_module: HistoryView,
      live_session: %{
        "user_id" => current_user.id,
        "workspace_id" => workspace_id,
        "tab" => Atom.to_string(tab)
      },
      live_id: "detail-history-#{tab}-#{workspace_id || "personal"}",
      title: "Conversations",
      sections: history_sections(tab)
    }
  end

  defp parse_history_tab("trash"), do: :trash
  defp parse_history_tab(_), do: :history

  defp history_sections(active) do
    [
      %{
        key: :history,
        label: "History",
        icon: "lucide-messages-square",
        href: "/history",
        active?: active == :history
      },
      %{
        key: :trash,
        label: "Trash",
        icon: "lucide-trash-2",
        href: "/history?tab=trash",
        active?: active == :trash
      }
    ]
  end

  # Search -------------------------------------------------------------------

  def build_search(params, current_user) do
    query = Map.get(params, "q", "")
    type = Map.get(params, "type", "all")

    %{
      type: :search,
      live_module: SearchView,
      live_session: %{"user_id" => current_user.id, "q" => query, "type" => type},
      live_id: "detail-search-#{:erlang.phash2({query, type})}",
      title: "Search",
      sections: search_filter_sections(type, query)
    }
  end

  defp search_filter_sections(active, q) do
    base = "/search?q=#{URI.encode_www_form(q)}"

    for {key_atom, key, label} <- [
          {:all, "all", "All"},
          {:conversations, "conversations", "Conversations"},
          {:brain, "brain", "Brain"},
          {:files, "files", "Files"},
          {:agents, "agents", "Agents"},
          {:prompts, "prompts", "Prompts"}
        ] do
      %{
        key: key_atom,
        label: label,
        href: base <> "&type=#{key}",
        active?: active == key
      }
    end
  end
end
