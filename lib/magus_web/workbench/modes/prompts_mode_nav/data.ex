defmodule MagusWeb.Workbench.Modes.PromptsModeNav.Data do
  @moduledoc """
  Data shaper for the workbench Prompts mode nav. Returns
  `[%Section{}]` ready to feed into `ResourceTree`.

  Personal workspace (workspace_id is nil): a single section of the
  actor's no-workspace prompts. Regular workspace: workspace-scoped
  prompts split into Shared and Personal via the
  `is_shared_to_workspace` calculation.

  Prompts render as leaf nodes; clicking emits `select_detail` on the
  parent LiveView (target: nil) since prompts open in the detail pane,
  not as tabs in v1.
  """

  alias MagusWeb.Workbench.Layout.ResourceTree.{Action, Section, Node}

  def load_sections(opts) do
    user = Map.fetch!(opts, :user)
    workspace_id = Map.get(opts, :workspace_id)
    search = String.downcase(Map.get(opts, :search_query) || "")
    target = Map.get(opts, :tree_target)
    filter = Map.get(opts, :nav_filter, :all)
    current_chat_conv_id = Map.get(opts, :current_chat_conv_id)

    favorites = list_favorites(user) |> filter_search(search)

    favorites_section =
      if favorites != [],
        do: [section(:favorites, "Favorites", favorites, target, current_chat_conv_id)]

    in_workspace? = not is_nil(workspace_id)
    {show_shared?, show_personal?} = visible_sections(in_workspace?, filter)

    base =
      if in_workspace? do
        []
        |> maybe_section(
          show_shared?,
          fn ->
            section(
              :shared,
              "Shared",
              list_prompts(:shared, workspace_id, user) |> filter_search(search),
              target,
              current_chat_conv_id
            )
          end
        )
        |> maybe_section(
          show_personal?,
          fn ->
            section(
              :personal,
              "Personal",
              list_prompts(:personal_in_ws, workspace_id, user) |> filter_search(search),
              target,
              current_chat_conv_id
            )
          end
        )
      else
        personal = list_prompts(:personal, nil, user)

        [
          section(
            :personal,
            nil,
            personal |> filter_search(search),
            target,
            current_chat_conv_id
          )
        ]
      end

    (favorites_section || []) ++ base
  end

  defp visible_sections(false, _filter), do: {false, true}
  defp visible_sections(true, :all), do: {true, true}
  defp visible_sections(true, :shared), do: {true, false}
  defp visible_sections(true, :personal), do: {false, true}
  defp visible_sections(true, _other), do: {true, true}

  defp maybe_section(sections, false, _fun), do: sections
  defp maybe_section(sections, true, fun), do: sections ++ [fun.()]

  defp list_favorites(user) do
    Magus.Library.my_favorite_prompts!(actor: user)
  rescue
    _ -> []
  end

  defp filter_search(items, ""), do: items

  defp filter_search(items, search) do
    Enum.filter(items, fn p ->
      String.contains?(String.downcase(p.name || ""), search)
    end)
  end

  defp list_prompts(:shared, workspace_id, user) do
    Magus.Library.workspace_prompts!(workspace_id, actor: user)
    |> Enum.filter(&Map.get(&1, :is_shared_to_workspace, false))
  rescue
    _ -> []
  end

  defp list_prompts(:personal_in_ws, workspace_id, user) do
    Magus.Library.workspace_prompts!(workspace_id, actor: user)
    |> Enum.reject(&Map.get(&1, :is_shared_to_workspace, false))
  rescue
    _ -> []
  end

  defp list_prompts(:personal, _workspace_id, user) do
    Magus.Library.my_prompts!(actor: user)
  rescue
    _ -> []
  end

  defp section(key, label, prompts, target, current_chat_conv_id) do
    %Section{
      key: key,
      label: label,
      nodes: Enum.map(prompts, &prompt_to_leaf(&1, current_chat_conv_id)),
      empty_message: empty_msg(key),
      target: target
    }
  end

  defp prompt_to_leaf(prompt, current_chat_conv_id) do
    Node.new_leaf(
      id: prompt.id,
      label: prompt.name || "Untitled prompt",
      icon: prompt_icon(prompt),
      resource_type: :prompt,
      click_event: %{
        event: "select_detail",
        values: %{"type" => "prompt", "id" => prompt.id},
        target: nil
      },
      actions: prompt_actions(prompt, current_chat_conv_id)
    )
  end

  defp prompt_actions(prompt, nil), do: [start_chat_action(prompt)]

  defp prompt_actions(prompt, conv_id) when is_binary(conv_id) do
    [
      start_chat_action(prompt),
      Action.new(
        icon: "lucide-play",
        event: "use_prompt_in_current",
        values: %{"id" => prompt.id, "conversation_id" => conv_id},
        target: nil,
        title: "Insert into current chat"
      )
    ]
  end

  defp start_chat_action(prompt) do
    Action.new(
      icon: "lucide-message-circle-plus",
      event: "use_prompt",
      values: %{"id" => prompt.id},
      target: nil,
      title: "Start chat with prompt"
    )
  end

  defp prompt_icon(%{type: :system}), do: "lucide-sparkles"
  defp prompt_icon(_), do: "lucide-scroll-text"

  defp empty_msg(:shared), do: "No shared prompts"
  defp empty_msg(:personal), do: "No prompts yet"
  defp empty_msg(_), do: nil
end
