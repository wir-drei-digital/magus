defmodule MagusWeb.Api.V2.PagesController do
  @moduledoc """
  Page CRUD over the markdown body. Single write path goes through
  `Magus.Brain.update_page_body/3` with `:base_version` for optimistic
  locking; title collisions return 409 with the existing page snapshot so
  callers can decide between replace/append/prepend.
  """

  use MagusWeb, :controller

  import MagusWeb.Api.V2.ControllerHelpers

  require Ash.Query

  alias Magus.Brain
  alias Magus.Brain.Page
  alias Magus.Brain.Page.Errors.VersionConflict
  alias MagusWeb.Api.Plugs.RequireWorkspaceMatch
  alias MagusWeb.Api.V2.ApiView

  @valid_modes ~w(replace append prepend create)

  def index(conn, %{"brain_id" => brain_id} = params) do
    user = conn.assigns.current_user

    with {:ok, brain} <- fetch_brain(brain_id, user),
         {:ok, conn} <- RequireWorkspaceMatch.check(conn, brain.workspace_id),
         {:ok, pages} <- Brain.list_pages(brain.id, actor: user) do
      payload =
        case params["as"] do
          "flat" -> Enum.map(pages, &serialize_summary/1)
          _ -> build_tree(pages)
        end

      json(conn, ApiView.data(payload))
    else
      {:error, %Plug.Conn{} = halted_conn} -> halted_conn
      _ -> not_found(conn)
    end
  end

  @doc """
  Lists pages filtered by tag. `tag` is required, `brain` is optional and
  may be either a brain id or slug. When omitted, the actor's accessible
  brains are spanned.
  """
  def index_by_tag(conn, %{"tag" => tag} = params) when is_binary(tag) and tag != "" do
    user = conn.assigns.current_user

    case resolve_optional_brain(params["brain"], user, conn) do
      {:ok, conn, brain_ids} ->
        rows = collect_pages_with_tag(brain_ids, tag, user)
        json(conn, ApiView.data(Enum.map(rows, &serialize_summary/1)))

      {:error, %Plug.Conn{} = halted_conn} ->
        halted_conn

      :not_found ->
        not_found(conn)
    end
  end

  def index_by_tag(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(ApiView.error("invalid_request", "Query parameter `tag` is required"))
  end

  def create(conn, %{"brain_id" => brain_id} = params) do
    user = conn.assigns.current_user

    with {:ok, brain} <- fetch_brain(brain_id, user),
         {:ok, conn} <- RequireWorkspaceMatch.check(conn, brain.workspace_id),
         {:ok, title} <- validate_title(params["title"]),
         :ok <- validate_create_mode(params["mode"]),
         {:ok, page} <- create_or_collide(brain.id, title, params, user, conn) do
      conn
      |> put_status(:created)
      |> json(ApiView.data(serialize_full(page)))
    else
      {:error, %Plug.Conn{} = halted_conn} ->
        halted_conn

      {:error, :invalid_title} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(ApiView.error("invalid_title", "Title is required"))

      {:error, :invalid_mode} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(
          ApiView.error(
            "invalid_mode",
            "mode must be one of: #{Enum.join(@valid_modes, ", ")}"
          )
        )

      {:error, {:collision, existing}} ->
        conn
        |> put_status(:conflict)
        |> json(
          ApiView.error("already_exists", "A page with that title already exists", existing)
        )

      {:error, %Ash.Error.Invalid{} = err} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(ApiView.error("write_failed", "Invalid page input", ash_errors(err)))

      {:error, _reason} ->
        not_found(conn)
    end
  end

  def show_by_slug(conn, %{"brain_id" => brain_id_or_slug, "slug" => page_slug} = params) do
    user = conn.assigns.current_user

    with {:ok, brain} <- fetch_brain(brain_id_or_slug, user),
         {:ok, conn} <- RequireWorkspaceMatch.check(conn, brain.workspace_id),
         {:ok, page} <- find_page_by_slug(brain.id, page_slug, user) do
      show(conn, Map.put(params, "id", page.id))
    else
      {:error, %Plug.Conn{} = halted_conn} -> halted_conn
      _ -> not_found(conn)
    end
  end

  defp find_page_by_slug(brain_id, slug, actor) do
    case Page
         |> Ash.Query.filter(brain_id == ^brain_id and slug == ^slug)
         |> Ash.read_one(actor: actor) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, page} -> {:ok, page}
      err -> err
    end
  end

  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, page} <- Brain.get_page(id, actor: user, load: [:brain]),
         {:ok, conn} <- RequireWorkspaceMatch.check(conn, page.brain.workspace_id) do
      json(conn, ApiView.data(serialize_full(page)))
    else
      {:error, %Plug.Conn{} = halted_conn} -> halted_conn
      _ -> not_found(conn)
    end
  end

  def update(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user

    with {:ok, page} <- Brain.get_page(id, actor: user, load: [:brain]),
         {:ok, conn} <- RequireWorkspaceMatch.check(conn, page.brain.workspace_id),
         {:ok, updated} <- apply_update(page, params, user) do
      json(conn, ApiView.data(serialize_full(updated)))
    else
      {:error, %Plug.Conn{} = halted_conn} ->
        halted_conn

      {:error, :no_valid_fields} ->
        conn
        |> put_status(:bad_request)
        |> json(ApiView.error("invalid_request", "Provide title, parent_page_id, or body + mode"))

      {:error, :invalid_mode} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(
          ApiView.error(
            "invalid_mode",
            "Body updates require mode: one of #{Enum.join(@valid_modes, ", ")}"
          )
        )

      {:error, {:version_conflict, payload}} ->
        conn
        |> put_status(:conflict)
        |> json(ApiView.error("version_conflict", "Page was modified concurrently", payload))

      {:error, %Ash.Error.Invalid{} = err} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(ApiView.error("validation_error", "Invalid page update", ash_errors(err)))

      _ ->
        not_found(conn)
    end
  end

  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, page} <- Brain.get_page(id, actor: user, load: [:brain]),
         {:ok, conn} <- RequireWorkspaceMatch.check(conn, page.brain.workspace_id),
         {:ok, deleted} <- Brain.soft_delete_page(page, actor: user) do
      json(conn, ApiView.data(%{id: deleted.id, deleted_at: deleted.deleted_at}))
    else
      {:error, %Plug.Conn{} = halted_conn} -> halted_conn
      _ -> not_found(conn)
    end
  end

  def clear(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, page} <- Brain.get_page(id, actor: user, load: [:brain]),
         {:ok, conn} <- RequireWorkspaceMatch.check(conn, page.brain.workspace_id),
         {:ok, updated} <- write_body(page, "", user) do
      json(conn, ApiView.data(serialize_full(updated)))
    else
      {:error, %Plug.Conn{} = halted_conn} ->
        halted_conn

      {:error, {:version_conflict, payload}} ->
        conn
        |> put_status(:conflict)
        |> json(ApiView.error("version_conflict", "Page was modified concurrently", payload))

      {:error, %Ash.Error.Invalid{} = err} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(ApiView.error("validation_error", "Could not clear page", ash_errors(err)))

      _ ->
        not_found(conn)
    end
  end

  def undo(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, page} <- Brain.get_page(id, actor: user, load: [:brain]),
         {:ok, conn} <- RequireWorkspaceMatch.check(conn, page.brain.workspace_id),
         {:ok, prior_body} <- find_prior_body(page.id),
         {:ok, updated} <- write_body(page, prior_body, user) do
      json(conn, ApiView.data(serialize_full(updated)))
    else
      {:error, %Plug.Conn{} = halted_conn} ->
        halted_conn

      {:error, :no_prior_version} ->
        conn
        |> put_status(:not_found)
        |> json(ApiView.error("no_prior_version", "No prior body version exists for this page"))

      {:error, {:version_conflict, payload}} ->
        conn
        |> put_status(:conflict)
        |> json(ApiView.error("version_conflict", "Page was modified concurrently", payload))

      {:error, %Ash.Error.Invalid{} = err} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(ApiView.error("validation_error", "Could not undo", ash_errors(err)))

      _ ->
        not_found(conn)
    end
  end

  # ---------------------------------------------------------------------------
  # Update dispatching
  # ---------------------------------------------------------------------------

  defp apply_update(page, %{"title" => title}, user) when is_binary(title) and title != "" do
    Brain.update_page_title(page, %{title: title}, actor: user)
  end

  defp apply_update(page, %{"parent_page_id" => parent_id}, user) do
    Brain.move_page_to_parent(page, %{parent_page_id: parent_id}, actor: user)
  end

  defp apply_update(page, %{"body" => body} = params, user) when is_binary(body) do
    mode = params["mode"]

    case normalize_body_mode(mode) do
      :invalid ->
        {:error, :invalid_mode}

      :replace ->
        write_body(page, strip_rogue_title(body, page.title), user)

      :append ->
        cleaned = strip_rogue_title(body, page.title)
        write_body(page, combine_append(page.body || "", cleaned), user)

      :prepend ->
        cleaned = strip_rogue_title(body, page.title)
        write_body(page, combine_prepend(page.body || "", cleaned), user)
    end
  end

  defp apply_update(_page, _params, _user), do: {:error, :no_valid_fields}

  defp normalize_body_mode("replace"), do: :replace
  defp normalize_body_mode("append"), do: :append
  defp normalize_body_mode("prepend"), do: :prepend
  defp normalize_body_mode(_), do: :invalid

  # ---------------------------------------------------------------------------
  # Write path
  # ---------------------------------------------------------------------------

  defp write_body(page, body, user) do
    case Brain.update_page_body(
           page,
           %{body: body, base_version: page.lock_version},
           actor: user
         ) do
      {:ok, updated} ->
        {:ok, updated}

      {:error, %Ash.Error.Invalid{errors: errors}} = err ->
        case Enum.find(errors, &match?(%VersionConflict{}, &1)) do
          %VersionConflict{} = conflict ->
            {:error, {:version_conflict, version_conflict_payload(page, conflict)}}

          _ ->
            err
        end

      other ->
        other
    end
  end

  defp version_conflict_payload(page, %VersionConflict{} = c) do
    %{
      existing_page_id: page.id,
      existing_page_title: page.title,
      current_body: c.current_body,
      current_version: c.current_version,
      body_preview: c.current_body |> to_string() |> String.slice(0, 200),
      last_modified_at: c.current_modified_at,
      conflicting_actor_id: c.conflicting_actor_id,
      base_version: c.base_version
    }
  end

  # ---------------------------------------------------------------------------
  # Create + collision
  # ---------------------------------------------------------------------------

  defp validate_title(title) when is_binary(title) do
    case String.trim(title) do
      "" -> {:error, :invalid_title}
      trimmed -> {:ok, trimmed}
    end
  end

  defp validate_title(_), do: {:error, :invalid_title}

  defp validate_create_mode(nil), do: :ok
  defp validate_create_mode("create"), do: :ok
  defp validate_create_mode(mode) when mode in @valid_modes, do: :ok
  defp validate_create_mode(_), do: {:error, :invalid_mode}

  defp create_or_collide(brain_id, title, params, user, _conn) do
    case Brain.find_page_by_title_ci(brain_id, title, actor: user) do
      {:ok, [existing | _]} ->
        {:error, {:collision, collision_payload(existing)}}

      _ ->
        do_create_with_body(brain_id, title, params, user)
    end
  end

  defp do_create_with_body(brain_id, title, params, user) do
    body = strip_rogue_title(params["body"] || "", title)
    parent_id = params["parent_page_id"]
    create_attrs = %{title: title}

    create_attrs =
      if parent_id, do: Map.put(create_attrs, :parent_page_id, parent_id), else: create_attrs

    with {:ok, page} <- Brain.create_page(brain_id, create_attrs, actor: user),
         {:ok, with_body} <- maybe_write_body(page, body, user) do
      {:ok, with_body}
    end
  end

  defp maybe_write_body(page, "", _user), do: {:ok, page}

  defp maybe_write_body(page, body, user) when is_binary(body) do
    write_body(page, body, user)
  end

  defp collision_payload(page) do
    body = page.body || ""

    %{
      existing_page_id: page.id,
      existing_page_title: page.title,
      body_preview: String.slice(body, 0, 200),
      last_modified_at: page.updated_at
    }
  end

  # ---------------------------------------------------------------------------
  # Undo
  # ---------------------------------------------------------------------------

  defp find_prior_body(page_id) do
    case Magus.Brain.Page.Version
         |> Ash.Query.filter(version_source_id == ^page_id)
         |> Ash.Query.filter(version_action_name == :update_body)
         |> Ash.read(authorize?: false) do
      {:ok, versions} ->
        sorted = Enum.sort_by(versions, & &1.version_inserted_at, {:desc, NaiveDateTime})

        case sorted do
          [] -> {:error, :no_prior_version}
          [_only] -> {:ok, ""}
          [_latest, prior | _] -> {:ok, prior.changes["body"] || prior.changes[:body] || ""}
        end

      _ ->
        {:error, :no_prior_version}
    end
  end

  # ---------------------------------------------------------------------------
  # Body transforms
  # ---------------------------------------------------------------------------

  defp combine_append("", addition), do: addition

  defp combine_append(existing, addition) do
    String.trim_trailing(existing) <> "\n\n" <> String.trim_leading(addition)
  end

  defp combine_prepend(existing, addition) when existing in [nil, ""], do: addition

  defp combine_prepend(existing, addition) do
    String.trim_trailing(addition) <> "\n\n" <> String.trim_leading(existing)
  end

  defp strip_rogue_title(body, _title) when body in [nil, ""], do: body || ""

  defp strip_rogue_title(body, title) when is_binary(body) and is_binary(title) do
    trimmed = String.trim_leading(body)
    target = "# " <> title

    cond do
      String.starts_with?(trimmed, target <> "\n") ->
        rest = String.replace_prefix(trimmed, target <> "\n", "")
        String.trim_leading(rest)

      trimmed == target ->
        ""

      true ->
        body
    end
  end

  defp strip_rogue_title(body, _title), do: body

  # ---------------------------------------------------------------------------
  # Tag index helpers
  # ---------------------------------------------------------------------------

  defp resolve_optional_brain(nil, user, conn) do
    {:ok, conn, accessible_brain_ids(user)}
  end

  defp resolve_optional_brain(brain_id_or_slug, user, conn) do
    case fetch_brain(brain_id_or_slug, user) do
      {:ok, brain} ->
        case RequireWorkspaceMatch.check(conn, brain.workspace_id) do
          {:ok, conn} -> {:ok, conn, [brain.id]}
          {:error, halted} -> {:error, halted}
        end

      _ ->
        :not_found
    end
  end

  defp accessible_brain_ids(actor) do
    Magus.Brain.BrainResource
    |> Ash.Query.filter(is_archived == false)
    |> Ash.read!(actor: actor)
    |> Enum.map(& &1.id)
  end

  defp collect_pages_with_tag(brain_ids, tag, actor) do
    brain_ids
    |> Enum.flat_map(fn brain_id ->
      case Brain.pages_with_tag(brain_id, tag, actor: actor) do
        {:ok, rows} -> rows
        _ -> []
      end
    end)
    |> Enum.map(& &1.page_id)
    |> Enum.uniq()
    |> Enum.flat_map(fn page_id ->
      case Brain.get_page(page_id, actor: actor) do
        {:ok, page} -> [page]
        _ -> []
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Serialization
  # ---------------------------------------------------------------------------

  defp serialize_summary(page) do
    %{
      id: page.id,
      slug: page.slug,
      title: page.title,
      brain_id: page.brain_id,
      parent_page_id: page.parent_page_id,
      depth: page.depth,
      updated_at: page.updated_at
    }
  end

  defp serialize_full(page) do
    %{
      id: page.id,
      title: page.title,
      slug: page.slug,
      body: page.body,
      lock_version: page.lock_version,
      frontmatter: page.frontmatter,
      brain_id: page.brain_id,
      parent_page_id: page.parent_page_id,
      depth: page.depth,
      inserted_at: page.inserted_at,
      updated_at: page.updated_at
    }
  end

  defp build_tree(pages) do
    by_parent = Enum.group_by(pages, & &1.parent_page_id)
    roots = Map.get(by_parent, nil, [])
    Enum.map(roots, &attach_children(&1, by_parent))
  end

  defp attach_children(page, by_parent) do
    children = Map.get(by_parent, page.id, [])

    page
    |> serialize_summary()
    |> Map.put(:children, Enum.map(children, &attach_children(&1, by_parent)))
  end
end
