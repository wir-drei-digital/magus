defmodule Magus.Agents.Tools.Brain.ReadBrain.Support do
  @moduledoc """
  Shared internals for the `ReadBrain` tool's action handler submodules
  (`Reads`, `Search`, `Curation`).

  This holds the pieces that are genuinely cross-cutting rather than
  owned by a single action group: the `current` echo + brain/breadcrumb
  loading, the page-lookup-for-reading resolution (including
  slash-path walking), the cross-brain resolution used by find_page /
  search / list_tags, and small body-slicing utilities used by
  read_page.

  Extracted verbatim from `Magus.Agents.Tools.Brain.ReadBrain` as part
  of the Task B11 dispatch-handler split; behavior is unchanged.
  """

  alias Magus.Brain
  alias Magus.Brain.Hierarchy
  alias Magus.Agents.Tools.Brain.BrainResolver

  import Magus.Agents.Tools.Helpers, only: [get_param: 2]

  # ---------------------------------------------------------------------------
  # read_page / peek_page helpers
  # ---------------------------------------------------------------------------

  def resolve_page_for_read(context, params, brain_id, ctx) do
    cond do
      page_id = get_param(params, :page_id) ->
        Brain.get_page(page_id, actor: ctx.user)

      page_title = get_param(params, :page_title) ->
        cond do
          slash_path?(page_title) ->
            segments = parse_slash(page_title)

            case resolve_leaf_via_chain(brain_id, segments, ctx) do
              {:ok, page} -> {:ok, page}
              :not_found -> {:error, "Page not found: #{page_title}"}
            end

          true ->
            case find_existing_page(brain_id, page_title, ctx) do
              {:ok, page} -> {:ok, page}
              :not_found -> {:error, "Page not found: '#{page_title}'"}
            end
        end

      pane_page_id = Map.get(context, :brain_page_id) || Map.get(context, "brain_page_id") ->
        Brain.get_page(pane_page_id, actor: ctx.user)

      true ->
        {:error,
         "No page specified. Provide page_id, page_title, or open a page in the brain pane."}
    end
  end

  def find_existing_page(brain_id, title, ctx) do
    case Brain.find_page_by_title(brain_id, title, actor: ctx.user) do
      {:ok, [page | _]} -> {:ok, page}
      {:ok, []} -> :not_found
      _ -> :not_found
    end
  end

  def parse_slash(path) do
    path
    |> String.split("/")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  def slash_path?(title) when is_binary(title) do
    title |> parse_slash() |> length() |> Kernel.>(1)
  end

  def slash_path?(_), do: false

  def resolve_leaf_via_chain(brain_id, segments, ctx) do
    walk_segments(brain_id, segments, nil, ctx)
  end

  defp walk_segments(_brain_id, [], _parent, _ctx), do: :not_found

  defp walk_segments(brain_id, [last], parent_id, ctx) do
    case Brain.find_page_by_title(brain_id, last, actor: ctx.user) do
      {:ok, pages} ->
        case Enum.find(pages, fn p -> p.parent_page_id == parent_id end) do
          nil -> :not_found
          page -> {:ok, page}
        end

      _ ->
        :not_found
    end
  end

  defp walk_segments(brain_id, [head | rest], parent_id, ctx) do
    case Brain.find_page_by_title(brain_id, head, actor: ctx.user) do
      {:ok, pages} ->
        case Enum.find(pages, fn p -> p.parent_page_id == parent_id end) do
          nil -> :not_found
          page -> walk_segments(brain_id, rest, page.id, ctx)
        end

      _ ->
        :not_found
    end
  end

  def slice_body(body, nil, nil, _total), do: {:ok, body}

  def slice_body(body, start_line, end_line, total) when is_integer(start_line) do
    end_line = end_line || total

    cond do
      start_line < 1 ->
        {:error, "start_line must be >= 1, got #{start_line}."}

      start_line > total ->
        {:error, "start_line #{start_line} exceeds line_count #{total}."}

      end_line < start_line ->
        {:error, "end_line (#{end_line}) must be >= start_line (#{start_line})."}

      true ->
        clamped = min(end_line, total)

        lines =
          body
          |> String.split("\n")
          |> Enum.slice((start_line - 1)..(clamped - 1))
          |> Enum.with_index(start_line)
          |> Enum.map(fn {line, idx} -> "#{idx}: #{line}" end)
          |> Enum.join("\n")

        {:ok, lines}
    end
  end

  def slice_body(body, _, end_line, total) when is_integer(end_line),
    do: slice_body(body, 1, end_line, total)

  def slice_body(body, _, _, _), do: {:ok, body}

  def line_count(""), do: 0
  def line_count(body) when is_binary(body), do: length(String.split(body, "\n"))
  def line_count(_), do: 0

  # ---------------------------------------------------------------------------
  # Helpers — brain pair resolution (cross-brain support)
  # ---------------------------------------------------------------------------

  # find_page / search / list_tags accept either an explicit brain_id, or
  # explicit `brain_id: nil` to span every accessible brain, or no key at
  # all (in which case we honor the active context brain_id and only fall
  # back to cross-brain when context too is unset). We always return
  # `[{brain_id, brain_title}]` so downstream code can decorate results
  # with the originating brain.
  def resolve_brain_pairs(params, context, ctx) do
    {has_key?, explicit_value} = fetch_brain_param(params)

    cond do
      has_key? and is_binary(explicit_value) and explicit_value != "" ->
        # Route through the resolver so the explicit value can be a brain id,
        # slug, or title (and is workspace-scoped), then fetch the brain.
        case BrainResolver.resolve_brain_id(context, params) do
          {:ok, brain_id} ->
            case Brain.get_brain(brain_id, actor: ctx.user) do
              {:ok, brain} -> [{brain.id, brain.title}]
              _ -> []
            end

          _ ->
            []
        end

      has_key? and is_nil(explicit_value) ->
        list_accessible_brain_pairs(context, ctx)

      true ->
        # Key omitted entirely: prefer the active context brain when set,
        # else span every accessible brain so the tool stays useful in
        # contexts without a pane.
        case BrainResolver.resolve_brain_id(context, params) do
          {:ok, brain_id} ->
            case Brain.get_brain(brain_id, actor: ctx.user) do
              {:ok, brain} -> [{brain.id, brain.title}]
              _ -> []
            end

          _ ->
            list_accessible_brain_pairs(context, ctx)
        end
    end
  end

  defp fetch_brain_param(params) do
    cond do
      Map.has_key?(params, :brain_id) -> {true, Map.get(params, :brain_id)}
      Map.has_key?(params, "brain_id") -> {true, Map.get(params, "brain_id")}
      true -> {false, nil}
    end
  end

  defp list_accessible_brain_pairs(context, ctx) do
    case BrainResolver.resolve_brain_ids(context, ctx.user) do
      {:ok, pairs} -> pairs
      _ -> []
    end
  end

  # ---------------------------------------------------------------------------
  # `current` echo + brain loading
  # ---------------------------------------------------------------------------

  def build_current(nil, nil), do: %{}

  def build_current(brain, nil) when is_map(brain) do
    %{brain_id: brain.id, brain_title: brain.title}
  end

  def build_current(nil, page) when is_map(page) do
    %{page_id: page.id, page_title: page.title}
  end

  def build_current(brain, page) when is_map(brain) and is_map(page) do
    %{
      brain_id: brain.id,
      brain_title: brain.title,
      page_id: page.id,
      page_title: page.title
    }
  end

  def load_brain(nil, _ctx), do: nil

  def load_brain(%{brain_id: brain_id}, ctx) do
    load_brain_by_id(brain_id, ctx)
  end

  def load_brain(_, _), do: nil

  def load_brain_by_id(nil, _ctx), do: nil

  def load_brain_by_id(brain_id, ctx) do
    case Brain.get_brain(brain_id, actor: ctx.user) do
      {:ok, brain} -> brain
      _ -> nil
    end
  end

  def build_breadcrumb(page, ctx) do
    case Brain.list_pages(page.brain_id, actor: ctx.user) do
      {:ok, all_pages} -> Hierarchy.build_breadcrumb(page, all_pages)
      _ -> page.title
    end
  end

  # ---------------------------------------------------------------------------
  # Misc
  # ---------------------------------------------------------------------------

  def blank?(nil), do: true
  def blank?(""), do: true
  def blank?(s) when is_binary(s), do: String.trim(s) == ""
  def blank?(_), do: false
end
