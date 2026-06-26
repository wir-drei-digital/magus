defmodule MagusWeb.Workbench.Tab.LabelResolver do
  @moduledoc """
  Helpers for deriving tab display labels and icons.

  Tab labels are resolved in **two stages** with intentionally different
  return contracts. Don't conflate them:

  ## Stage 1 — `label_for_primary/2` (write-time)

  Called by `MagusWeb.Workbench.Live.TabActions` when *opening* a tab.
  Takes a bare `primary` map (`%{"type" => ..., "id" => ...}`) and returns
  either a resolved string (the persisted label) or `nil`. A `nil` return
  means "no explicit label, defer rendering to stage 2." The OpenTab Ash
  change in `lib/magus/workbench/tab_session/changes/open_tab.ex` accepts
  `nil` and stores it as-is.

  ## Stage 2 — `label_for/1` and `label_for/2` (render-time)

  Called by tab-bar / tabs-pill components when *rendering* an existing
  tab. Takes a full tab map (`%{"label" => ..., "primary" => %{...}}`).
  Returns a non-nil string in all cases — explicit label if present,
  type-specific fallback ("Agent", "Prompt", "Untitled file", ...) on
  lookup failure, generic "Untitled" otherwise.

  The asymmetry is deliberate: write-time can defer resolution, render-time
  must produce a string the user can see.

  Icons (`icon_for/1`) are derived statically from `tab["primary"]["type"]`.
  Companion labels and icons follow the same render-time contract via
  `companion_label_for/2` and `companion_icon_for/1`.
  """

  use Gettext, backend: MagusWeb.Gettext

  @spec label_for(map()) :: String.t()
  def label_for(%{"label" => label}) when is_binary(label) and label != "", do: label
  def label_for(_tab), do: "Untitled"

  @doc """
  Render-time label resolution. Always returns a non-nil string. Uses the
  tab's explicit `"label"` if set; otherwise does a type-specific DB
  lookup with a fallback string on miss. Pair with `label_for_primary/2`
  (the write-time variant that may return `nil`).
  """
  @spec label_for(map(), map() | nil) :: String.t()
  def label_for(%{"label" => label}, _user) when is_binary(label) and label != "", do: label

  def label_for(%{"primary" => %{"type" => "file", "id" => id}}, user) when not is_nil(user) do
    case Magus.Files.get_file(id, actor: user) do
      {:ok, file} -> file.name
      _ -> "Untitled file"
    end
  end

  def label_for(%{"primary" => %{"type" => "agent", "id" => "new"}}, _user), do: "New agent"

  def label_for(%{"primary" => %{"type" => "agent", "id" => id}}, user) when not is_nil(user) do
    case Magus.Agents.get_custom_agent(id, actor: user) do
      {:ok, agent} -> agent.name || "Agent"
      _ -> "Agent"
    end
  end

  def label_for(%{"primary" => %{"type" => "prompt", "id" => "new"}}, _user), do: "New prompt"

  def label_for(%{"primary" => %{"type" => "prompt", "id" => id}}, user) when not is_nil(user) do
    case Magus.Library.get_prompt(id, actor: user) do
      {:ok, prompt} -> prompt.name || "Prompt"
      _ -> "Prompt"
    end
  end

  def label_for(tab, _user), do: label_for(tab)

  @doc """
  Write-time label resolution. Returns the persisted label for a freshly
  opened tab, or `nil` to defer rendering to `label_for/1` later.

  The `nil` returns are intentional sentinels — the OpenTab Ash change
  stores them, and the tab bar later falls back via `label_for/1`. Do not
  add string fallbacks here; that would obscure missing-resource cases at
  render time and produce stale labels on resource updates.
  """
  @spec label_for_primary(map() | nil, Ash.Resource.record() | nil) :: String.t() | nil
  def label_for_primary(%{"type" => "conversation", "id" => "new"}, _user), do: "New chat"

  def label_for_primary(%{"type" => "conversation", "id" => id}, user) do
    case Magus.Chat.get_conversation(id, actor: user) do
      {:ok, conv} -> conv.title || "Untitled conversation"
      _ -> nil
    end
  end

  def label_for_primary(%{"type" => "brain_page", "id" => id}, user) do
    case Magus.Brain.get_page(id, actor: user) do
      {:ok, page} -> page.title
      _ -> nil
    end
  end

  def label_for_primary(%{"type" => "file", "id" => id}, user) do
    case Magus.Files.get_file(id, actor: user) do
      {:ok, file} -> file.name
      _ -> nil
    end
  end

  def label_for_primary(%{"type" => "agent", "id" => "new"}, _user), do: "New agent"

  def label_for_primary(%{"type" => "agent", "id" => id}, user) do
    case Magus.Agents.get_custom_agent(id, actor: user) do
      {:ok, agent} -> agent.name
      _ -> nil
    end
  end

  def label_for_primary(%{"type" => "prompt", "id" => "new"}, _user), do: "New prompt"

  def label_for_primary(%{"type" => "prompt", "id" => id}, user) do
    case Magus.Library.get_prompt(id, actor: user) do
      {:ok, prompt} -> prompt.name
      _ -> nil
    end
  end

  def label_for_primary(%{"type" => "file_browser", "scope" => "my_files"}, _user),
    do: gettext("My Files")

  def label_for_primary(%{"type" => "file_browser", "scope" => "shared"}, _user),
    do: gettext("Shared with me")

  def label_for_primary(%{"type" => "file_browser", "scope" => "recent"}, _user),
    do: gettext("Recent")

  def label_for_primary(%{"type" => "file_browser", "scope" => "templates"}, _user),
    do: gettext("Templates")

  def label_for_primary(%{"type" => "file_browser", "scope" => "trash"}, _user),
    do: gettext("Trash")

  def label_for_primary(%{"type" => "file_browser", "scope" => "folder", "id" => id}, user) do
    case Magus.Chat.get_folder(id, actor: user) do
      {:ok, folder} -> folder.name || gettext("Untitled folder")
      _ -> gettext("Folder")
    end
  end

  def label_for_primary(
        %{"type" => "file_browser", "scope" => "knowledge", "id" => id},
        user
      ) do
    case Magus.Knowledge.get_collection(id, actor: user) do
      {:ok, coll} -> coll.name || gettext("Collection")
      _ -> gettext("Collection")
    end
  end

  def label_for_primary(_, _user), do: nil

  @spec icon_for(map()) :: String.t()
  def icon_for(%{"primary" => %{"type" => "conversation"}}), do: "lucide-message-square"
  def icon_for(%{"primary" => %{"type" => "brain_page"}}), do: "lucide-file-text"
  def icon_for(%{"primary" => %{"type" => "brain"}}), do: "lucide-brain"
  def icon_for(%{"primary" => %{"type" => "agent"}}), do: "lucide-bot"
  def icon_for(%{"primary" => %{"type" => "prompt"}}), do: "lucide-scroll-text"
  def icon_for(%{"primary" => %{"type" => "file"}}), do: "lucide-file"
  def icon_for(_), do: "lucide-file"

  @spec companion_label_for(map(), map() | nil) :: String.t()
  def companion_label_for(%{"type" => "draft", "id" => id}, user) do
    case Magus.Drafts.get_draft(id, actor: user) do
      {:ok, %{title: title}} when is_binary(title) and title != "" -> title
      _ -> "Draft"
    end
  end

  def companion_label_for(%{"type" => "thread", "id" => id}, user) do
    case Magus.Chat.get_conversation(id, actor: user) do
      {:ok, %{title: title}} when is_binary(title) and title != "" -> title
      _ -> "Thread"
    end
  end

  def companion_label_for(%{"type" => "service"}, _user), do: "Service"

  def companion_label_for(%{"type" => "pdf", "name" => name}, _user)
      when is_binary(name) and name != "",
      do: name

  def companion_label_for(%{"type" => "pdf"}, _user), do: "PDF"

  def companion_label_for(%{"type" => "spreadsheet", "name" => name}, _user)
      when is_binary(name) and name != "",
      do: name

  def companion_label_for(%{"type" => "spreadsheet"}, _user), do: "Spreadsheet"

  def companion_label_for(%{"type" => "brain_page", "id" => id}, user) do
    case Magus.Brain.get_page(id, actor: user) do
      {:ok, %{title: title}} when is_binary(title) and title != "" -> title
      _ -> "Brain page"
    end
  end

  def companion_label_for(_spec, _user), do: "Companion"

  @spec companion_icon_for(map()) :: String.t()
  def companion_icon_for(%{"type" => "draft"}), do: "lucide-pencil-line"
  def companion_icon_for(%{"type" => "thread"}), do: "lucide-git-branch"
  def companion_icon_for(%{"type" => "service"}), do: "lucide-globe"
  def companion_icon_for(%{"type" => "pdf"}), do: "lucide-file-text"
  def companion_icon_for(%{"type" => "spreadsheet"}), do: "lucide-table-2"
  def companion_icon_for(%{"type" => "brain_page"}), do: "lucide-file-text"
  def companion_icon_for(_), do: "lucide-square"
end
