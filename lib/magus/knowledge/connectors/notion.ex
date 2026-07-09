defmodule Magus.Knowledge.Connectors.Notion do
  @moduledoc """
  Knowledge connector for Notion workspaces.

  Uses the Notion API to list databases (as folders), query pages within
  databases, and fetch page content converted to markdown.

  Handles Notion's rate limits (avg 3 req/s) by respecting 429 Retry-After
  headers with automatic retry.

  ## Auth Config

      # OAuth (preferred)
      %{"access_token" => "ntn_..."}

      # Legacy internal integration token
      %{"api_key" => "ntn_..."}

  """

  @behaviour Magus.Knowledge.Connector

  require Logger

  @default_base_url "https://api.notion.com/v1"
  @notion_version "2022-06-28"
  @max_block_depth 10

  defp base_url, do: Application.get_env(:magus, :notion_base_url, @default_base_url)

  # token holds the Bearer token regardless of whether it came from OAuth or an API key
  defstruct [:token]

  # --- Connector callbacks ---

  @impl true
  def connect(%{"access_token" => token}) when is_binary(token) and token != "" do
    {:ok, %__MODULE__{token: token}}
  end

  def connect(%{"api_key" => api_key}) when is_binary(api_key) and api_key != "" do
    {:ok, %__MODULE__{token: api_key}}
  end

  def connect(_auth_config) do
    {:error, :missing_credentials}
  end

  @impl true
  def list_folders(%__MODULE__{} = conn, nil) do
    # Top-level: search for workspace-level pages and databases.
    # Users browse the page tree and discover databases as children.
    case search_workspace_root(conn) do
      {:ok, items} ->
        folders =
          items
          |> Enum.map(&search_result_to_folder/1)
          |> Enum.sort_by(& &1.name)

        {:ok, folders}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def list_folders(%__MODULE__{} = conn, path) do
    # Expanding a page: use the blocks API to find child pages and databases.
    page_id = String.trim_leading(path, "/page/") |> String.trim_leading("/")

    case fetch_page_children(conn, page_id) do
      {:ok, children} ->
        folders =
          children
          |> Enum.filter(fn block -> block["type"] in ["child_database", "child_page"] end)
          |> Enum.map(fn block ->
            case block["type"] do
              "child_database" ->
                title = non_empty(get_in(block, ["child_database", "title"]), "Untitled")
                %{id: block["id"], name: title, path: "/#{block["id"]}", icon: "database"}

              "child_page" ->
                title = non_empty(get_in(block, ["child_page", "title"]), "Untitled")
                %{id: block["id"], name: title, path: "/page/#{block["id"]}", icon: "page"}
            end
          end)

        {:ok, folders}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp search_result_to_folder(%{"object" => "database"} = db) do
    %{id: db["id"], name: extract_title(db), path: "/#{db["id"]}", icon: "database"}
  end

  defp search_result_to_folder(%{"object" => "page"} = page) do
    %{id: page["id"], name: extract_page_title(page), path: "/page/#{page["id"]}", icon: "page"}
  end

  defp search_workspace_root(conn, cursor \\ nil, acc \\ []) do
    # Search returns all accessible items; we filter to workspace-level only.
    body = %{page_size: 100} |> maybe_add_cursor(cursor)

    case post(conn, "/search", body) do
      {:ok, %{"results" => results} = response} ->
        workspace_items =
          Enum.filter(results, fn item ->
            get_in(item, ["parent", "type"]) == "workspace"
          end)

        all = [workspace_items | acc]

        if response["has_more"] do
          search_workspace_root(conn, response["next_cursor"], all)
        else
          {:ok, all |> Enum.reverse() |> List.flatten()}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_page_children(conn, page_id, cursor \\ nil, acc \\ []) do
    params =
      if cursor do
        [start_cursor: cursor, page_size: 100]
      else
        [page_size: 100]
      end

    case get(conn, "/blocks/#{page_id}/children", params) do
      {:ok, %{"results" => blocks} = response} ->
        if response["has_more"] do
          fetch_page_children(conn, page_id, response["next_cursor"], [blocks | acc])
        else
          {:ok, [blocks | acc] |> Enum.reverse() |> List.flatten()}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def list_items(%__MODULE__{} = conn, collection, cursor) do
    if page_collection?(collection) do
      list_page_items(conn, collection)
    else
      list_database_items(conn, collection, cursor)
    end
  end

  defp page_collection?(collection) do
    path = collection_path(collection)
    String.starts_with?(path, "/page/")
  end

  defp collection_path(%{external_path: p}) when is_binary(p), do: p
  defp collection_path(%{"external_path" => p}) when is_binary(p), do: p
  defp collection_path(%{path: p}) when is_binary(p), do: p
  defp collection_path(%{"path" => p}) when is_binary(p), do: p
  defp collection_path(_), do: "/"

  defp list_database_items(conn, collection, cursor) do
    database_id = collection_id(collection)

    body =
      if cursor do
        %{start_cursor: cursor["start_cursor"], page_size: 100}
      else
        %{page_size: 100}
      end

    case post(conn, "/databases/#{database_id}/query", body) do
      {:ok, %{"results" => results} = response} ->
        items =
          Enum.map(results, fn page ->
            %{
              id: page["id"],
              name: extract_page_title(page),
              etag: page["last_edited_time"],
              updated_at: parse_datetime(page["last_edited_time"]),
              mime_type: "text/markdown"
            }
          end)

        new_cursor =
          if response["has_more"] do
            %{"start_cursor" => response["next_cursor"]}
          else
            nil
          end

        {:ok, items, new_cursor}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp list_page_items(conn, collection) do
    page_id = collection_id(collection)

    case discover_child_pages(conn, page_id, 0) do
      {:ok, pages} ->
        # Include the selected page itself plus all sub-pages
        parent_item = build_page_item(conn, page_id)

        items =
          [parent_item | pages]
          |> Enum.reject(&is_nil/1)

        {:ok, items, nil}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_page_item(conn, page_id) do
    case get(conn, "/pages/#{page_id}", []) do
      {:ok, page} ->
        %{
          id: page["id"],
          name: extract_page_title(page),
          etag: page["last_edited_time"],
          updated_at: parse_datetime(page["last_edited_time"]),
          mime_type: "text/markdown"
        }

      {:error, _} ->
        nil
    end
  end

  defp discover_child_pages(_conn, _page_id, depth) when depth >= @max_block_depth, do: {:ok, []}

  defp discover_child_pages(conn, page_id, depth) do
    case fetch_page_children(conn, page_id) do
      {:ok, blocks} ->
        child_pages =
          blocks
          |> Enum.filter(&(&1["type"] == "child_page"))
          |> Enum.map(fn block ->
            %{
              id: block["id"],
              name: non_empty(get_in(block, ["child_page", "title"]), "Untitled"),
              etag: block["last_edited_time"],
              updated_at: parse_datetime(block["last_edited_time"]),
              mime_type: "text/markdown"
            }
          end)

        # Recurse into child pages to find nested sub-pages
        nested =
          Enum.reduce_while(child_pages, {:ok, []}, fn page, {:ok, acc} ->
            case discover_child_pages(conn, page.id, depth + 1) do
              {:ok, sub_pages} -> {:cont, {:ok, [sub_pages | acc]}}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end)

        case nested do
          {:ok, nested_pages} ->
            {:ok, child_pages ++ (nested_pages |> Enum.reverse() |> List.flatten())}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def fetch_content(%__MODULE__{} = conn, item) do
    page_id = item_id(item)

    case fetch_all_blocks(conn, page_id, nil, [], 0) do
      {:ok, blocks} ->
        markdown = blocks_to_markdown(blocks)
        metadata = %{"page_id" => page_id, "format" => "markdown"}
        {:ok, markdown, metadata}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def detect_changes(%__MODULE__{} = conn, collection, %DateTime{} = since) do
    if page_collection?(collection) do
      # Page collections don't support incremental change detection;
      # the sync framework falls back to full listing + etag comparison.
      {:error, :not_supported}
    else
      database_id = collection_id(collection)
      fetch_changes_page(conn, database_id, since, nil, [])
    end
  end

  defp fetch_changes_page(conn, database_id, since, cursor, acc) do
    body =
      %{
        filter: %{
          timestamp: "last_edited_time",
          last_edited_time: %{
            after: DateTime.to_iso8601(since)
          }
        },
        page_size: 100
      }
      |> maybe_add_cursor(cursor)

    case post(conn, "/databases/#{database_id}/query", body) do
      {:ok, %{"results" => results, "has_more" => has_more, "next_cursor" => next_cursor}} ->
        changes = Enum.map(results, &build_change(&1, since))

        if has_more do
          fetch_changes_page(conn, database_id, since, next_cursor, [changes | acc])
        else
          {:ok, [changes | acc] |> Enum.reverse() |> List.flatten()}
        end

      {:ok, %{"results" => results}} ->
        changes = Enum.map(results, &build_change(&1, since))
        {:ok, [changes | acc] |> Enum.reverse() |> List.flatten()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_change(page, since) do
    item = %{
      id: page["id"],
      name: extract_page_title(page),
      etag: page["last_edited_time"],
      updated_at: parse_datetime(page["last_edited_time"]),
      mime_type: "text/markdown"
    }

    created_at = parse_datetime(page["created_time"])
    type = if DateTime.compare(created_at, since) == :gt, do: :created, else: :updated

    %{type: type, item: item}
  end

  defp maybe_add_cursor(body, nil), do: body
  defp maybe_add_cursor(body, cursor), do: Map.put(body, :start_cursor, cursor)

  @impl true
  def register_webhook(_conn, _collection, _callback_url) do
    {:error, :not_supported}
  end

  @impl true
  def create_item(_conn, _collection, _name, _content, _metadata) do
    {:error, :not_supported}
  end

  @impl true
  def update_item(_conn, _collection, _external_id, _content, _metadata) do
    {:error, :not_supported}
  end

  # --- Private helpers ---

  defp post(conn, path, body, retries \\ 0) do
    url = base_url() <> path

    case Req.post(url,
           json: body,
           headers: headers(conn.token),
           receive_timeout: 30_000
         ) do
      {:ok, %Req.Response{status: 200, body: resp_body}} ->
        {:ok, resp_body}

      {:ok, %Req.Response{status: 429} = response} ->
        maybe_retry(:post, conn, path, body, retries, response)

      {:ok, %Req.Response{status: status, body: resp_body}} ->
        Logger.warning("Notion API error: status=#{status} body=#{inspect(resp_body)}")
        {:error, {:notion_api_error, status, resp_body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp get(conn, path, params, retries \\ 0) do
    url = base_url() <> path

    case Req.get(url,
           params: params,
           headers: headers(conn.token),
           receive_timeout: 30_000
         ) do
      {:ok, %Req.Response{status: 200, body: resp_body}} ->
        {:ok, resp_body}

      {:ok, %Req.Response{status: 429} = response} ->
        maybe_retry(:get, conn, path, params, retries, response)

      {:ok, %Req.Response{status: status, body: resp_body}} ->
        Logger.warning("Notion API error: status=#{status} body=#{inspect(resp_body)}")
        {:error, {:notion_api_error, status, resp_body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp maybe_retry(method, conn, path, body_or_params, retries, response) when retries < 3 do
    retry_after = retry_after_seconds(response)

    Logger.warning(
      "Notion API rate limited (429), retrying in #{retry_after}s (attempt #{retries + 1}/3)"
    )

    Process.sleep(retry_after * 1_000)

    case method do
      :post -> post(conn, path, body_or_params, retries + 1)
      :get -> get(conn, path, body_or_params, retries + 1)
    end
  end

  defp maybe_retry(_method, _conn, _path, _body_or_params, _retries, response) do
    Logger.warning("Notion API rate limited (429), max retries exhausted")
    {:error, {:notion_api_error, 429, response.body}}
  end

  defp retry_after_seconds(%Req.Response{} = response) do
    case Req.Response.get_header(response, "retry-after") do
      [value | _] -> parse_retry_after(value)
      _ -> 1
    end
  end

  defp parse_retry_after(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, _} when seconds > 0 and seconds <= 60 -> seconds
      _ -> 1
    end
  end

  defp parse_retry_after(_), do: 1

  defp headers(api_key) do
    [
      {"authorization", "Bearer #{api_key}"},
      {"notion-version", @notion_version}
    ]
  end

  defp fetch_all_blocks(conn, block_id, start_cursor, acc, depth) do
    params =
      if start_cursor do
        [start_cursor: start_cursor, page_size: 100]
      else
        [page_size: 100]
      end

    case get(conn, "/blocks/#{block_id}/children", params) do
      {:ok, %{"results" => blocks} = response} ->
        expanded_blocks = expand_children(conn, blocks, depth)

        if response["has_more"] do
          fetch_all_blocks(
            conn,
            block_id,
            response["next_cursor"],
            [expanded_blocks | acc],
            depth
          )
        else
          {:ok, [expanded_blocks | acc] |> Enum.reverse() |> List.flatten()}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp expand_children(_conn, blocks, depth) when depth >= @max_block_depth, do: blocks

  defp expand_children(conn, blocks, depth) do
    Enum.flat_map(blocks, fn block ->
      if block["has_children"] do
        case fetch_all_blocks(conn, block["id"], nil, [], depth + 1) do
          {:ok, children} ->
            [Map.put(block, "_children", children)]

          {:error, reason} ->
            Logger.warning(
              "Failed to fetch children for Notion block #{block["id"]}: #{inspect(reason)}"
            )

            [block]
        end
      else
        [block]
      end
    end)
  end

  # --- Title extraction ---

  defp extract_title(database) do
    case database["title"] do
      [%{"plain_text" => text} | _] -> text
      _ -> "Untitled"
    end
  end

  defp extract_page_title(page) do
    properties = page["properties"] || %{}

    # Find the title property (type == "title")
    title_prop =
      Enum.find_value(properties, fn {_key, prop} ->
        if prop["type"] == "title", do: prop
      end)

    case title_prop do
      %{"title" => [%{"plain_text" => text} | _]} -> text
      _ -> "Untitled"
    end
  end

  # --- Block to markdown conversion ---

  defp blocks_to_markdown(blocks) do
    blocks
    |> Enum.map(&block_to_markdown/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp block_to_markdown(%{"type" => "paragraph"} = block) do
    rich_text_to_string(get_in(block, ["paragraph", "rich_text"]))
  end

  defp block_to_markdown(%{"type" => "heading_1"} = block) do
    text = rich_text_to_string(get_in(block, ["heading_1", "rich_text"]))
    "# #{text}"
  end

  defp block_to_markdown(%{"type" => "heading_2"} = block) do
    text = rich_text_to_string(get_in(block, ["heading_2", "rich_text"]))
    "## #{text}"
  end

  defp block_to_markdown(%{"type" => "heading_3"} = block) do
    text = rich_text_to_string(get_in(block, ["heading_3", "rich_text"]))
    "### #{text}"
  end

  defp block_to_markdown(%{"type" => "bulleted_list_item"} = block) do
    text = rich_text_to_string(get_in(block, ["bulleted_list_item", "rich_text"]))
    children_md = render_children(block, "  ")
    "- #{text}#{children_md}"
  end

  defp block_to_markdown(%{"type" => "numbered_list_item"} = block) do
    # Markdown renderers auto-number sequential `1.` items
    text = rich_text_to_string(get_in(block, ["numbered_list_item", "rich_text"]))
    children_md = render_children(block, "  ")
    "1. #{text}#{children_md}"
  end

  defp block_to_markdown(%{"type" => "code"} = block) do
    text = rich_text_to_string(get_in(block, ["code", "rich_text"]))
    language = get_in(block, ["code", "language"]) || ""
    "```#{language}\n#{text}\n```"
  end

  defp block_to_markdown(%{"type" => "quote"} = block) do
    text = rich_text_to_string(get_in(block, ["quote", "rich_text"]))

    text
    |> String.split("\n")
    |> Enum.map_join("\n", &("> " <> &1))
  end

  defp block_to_markdown(%{"type" => "callout"} = block) do
    text = rich_text_to_string(get_in(block, ["callout", "rich_text"]))
    icon = get_in(block, ["callout", "icon", "emoji"]) || ""
    prefix = if icon != "", do: "#{icon} ", else: ""
    "> #{prefix}#{text}"
  end

  defp block_to_markdown(%{"type" => "divider"}), do: "---"

  defp block_to_markdown(%{"type" => "toggle"} = block) do
    text = rich_text_to_string(get_in(block, ["toggle", "rich_text"]))
    children_md = render_children(block)
    "**#{text}**#{children_md}"
  end

  defp block_to_markdown(%{"type" => "to_do"} = block) do
    text = rich_text_to_string(get_in(block, ["to_do", "rich_text"]))
    checked = get_in(block, ["to_do", "checked"])
    checkbox = if checked, do: "[x]", else: "[ ]"
    "- #{checkbox} #{text}"
  end

  defp block_to_markdown(%{"type" => "image"} = block) do
    caption = rich_text_to_string(get_in(block, ["image", "caption"]))
    url = get_in(block, ["image", "file", "url"]) || get_in(block, ["image", "external", "url"])

    if url do
      alt = if caption != "", do: caption, else: "image"
      "![#{alt}](#{url})"
    else
      nil
    end
  end

  defp block_to_markdown(%{"type" => "bookmark"} = block) do
    caption = rich_text_to_string(get_in(block, ["bookmark", "caption"]))
    url = get_in(block, ["bookmark", "url"])

    if url do
      label = if caption != "", do: caption, else: url
      "[#{label}](#{url})"
    else
      nil
    end
  end

  defp block_to_markdown(%{"type" => "table"} = block) do
    case block["_children"] do
      rows when is_list(rows) and rows != [] ->
        table_rows =
          Enum.map(rows, fn row ->
            cells = get_in(row, ["table_row", "cells"]) || []

            cells
            |> Enum.map(&rich_text_to_string/1)
            |> Enum.join(" | ")
            |> then(&"| #{&1} |")
          end)

        case table_rows do
          [header | rest] ->
            col_count = length(get_in(List.first(rows), ["table_row", "cells"]) || [])

            separator =
              "| " <> Enum.map_join(1..max(col_count, 1), " | ", fn _ -> "---" end) <> " |"

            Enum.join([header, separator | rest], "\n")

          _ ->
            Enum.join(table_rows, "\n")
        end

      _ ->
        nil
    end
  end

  # table_row blocks are rendered as part of the parent table block
  defp block_to_markdown(%{"type" => "table_row"}), do: nil

  defp block_to_markdown(%{"type" => "equation"} = block) do
    expression = get_in(block, ["equation", "expression"]) || ""
    "$$\n#{expression}\n$$"
  end

  defp block_to_markdown(%{"type" => "child_page"} = block) do
    title = non_empty(get_in(block, ["child_page", "title"]), "Untitled")
    "**#{title}** (linked page)"
  end

  defp block_to_markdown(%{"type" => "child_database"} = block) do
    title = non_empty(get_in(block, ["child_database", "title"]), "Untitled")
    "**#{title}** (linked database)"
  end

  defp block_to_markdown(%{"type" => "file"} = block) do
    caption = rich_text_to_string(get_in(block, ["file", "caption"]))
    url = get_in(block, ["file", "file", "url"]) || get_in(block, ["file", "external", "url"])

    if url do
      label = if caption != "", do: caption, else: Path.basename(URI.parse(url).path || "file")
      "[#{label}](#{url})"
    else
      nil
    end
  end

  defp block_to_markdown(%{"type" => "video"} = block) do
    url = get_in(block, ["video", "file", "url"]) || get_in(block, ["video", "external", "url"])
    if url, do: "[Video](#{url})", else: nil
  end

  defp block_to_markdown(%{"type" => "embed"} = block) do
    url = get_in(block, ["embed", "url"])
    if url, do: "[Embed](#{url})", else: nil
  end

  defp block_to_markdown(%{"type" => "link_preview"} = block) do
    url = get_in(block, ["link_preview", "url"])
    if url, do: "[#{url}](#{url})", else: nil
  end

  # Structural blocks — render children only
  defp block_to_markdown(%{"type" => type} = block)
       when type in ["column_list", "column", "synced_block"] do
    render_children(block) |> String.trim_leading("\n\n")
  end

  defp block_to_markdown(%{"type" => type}) do
    Logger.debug("Skipping unsupported Notion block type: #{type}")
    nil
  end

  defp block_to_markdown(_), do: nil

  defp render_children(block, indent \\ "") do
    case block["_children"] do
      children when is_list(children) and children != [] ->
        md =
          children
          |> Enum.map(&block_to_markdown/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.map_join("\n", fn line ->
            line
            |> String.split("\n")
            |> Enum.map_join("\n", &(indent <> &1))
          end)

        "\n#{md}"

      _ ->
        ""
    end
  end

  # --- Rich text helpers ---

  defp rich_text_to_string(nil), do: ""
  defp rich_text_to_string([]), do: ""

  defp rich_text_to_string(rich_text) when is_list(rich_text) do
    Enum.map_join(rich_text, "", fn segment ->
      text = segment["plain_text"] || ""
      annotations = segment["annotations"] || %{}

      text
      |> maybe_wrap(annotations["bold"], "**")
      |> maybe_wrap(annotations["italic"], "_")
      |> maybe_wrap(annotations["code"], "`")
      |> maybe_wrap(annotations["strikethrough"], "~~")
      |> maybe_link(segment["href"])
    end)
  end

  defp maybe_wrap(text, true, marker), do: "#{marker}#{text}#{marker}"
  defp maybe_wrap(text, _, _marker), do: text

  defp maybe_link(text, nil), do: text
  defp maybe_link(text, ""), do: text
  defp maybe_link(text, href), do: "[#{text}](#{href})"

  # --- Utility ---

  defp collection_id(%{external_id: id}), do: id
  defp collection_id(%{"external_id" => id}), do: id
  defp collection_id(%{id: id}), do: id
  defp collection_id(%{"id" => id}), do: id

  defp item_id(%{id: id}), do: id
  defp item_id(%{"id" => id}), do: id

  defp non_empty(nil, default), do: default
  defp non_empty("", default), do: default
  defp non_empty(value, _default), do: value

  defp parse_datetime(nil), do: DateTime.utc_now()

  defp parse_datetime(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end
end
