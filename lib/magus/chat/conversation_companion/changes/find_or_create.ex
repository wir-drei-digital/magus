defmodule Magus.Chat.ConversationCompanion.Changes.FindOrCreate do
  @moduledoc """
  Generic action runner for `:find_or_create_companion`. Returns the
  ConversationCompanion struct (with `:conversation` loaded) for the given
  `(resource_type, resource_id, actor)` tuple, creating both the
  conversation and the companion row if no link exists yet.
  """
  use Ash.Resource.Actions.Implementation

  require Logger

  alias Magus.Chat
  alias Magus.Chat.ConversationCompanion

  @impl true
  def run(input, _opts, %{actor: %{} = actor} = context) do
    rt = input.arguments.resource_type
    rid = input.arguments.resource_id
    opts = Ash.Context.to_opts(context)

    case Chat.get_companion_by_resource(rt, rid, opts) do
      {:ok, link} ->
        load_with_conversation(link, opts)

      {:error, %Ash.Error.Invalid{errors: errors}} = err ->
        if Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1)) do
          create_link(rt, rid, actor, opts)
        else
          err
        end

      other ->
        other
    end
  end

  def run(_input, _opts, _context), do: {:error, :missing_actor}

  defp create_link(rt, rid, actor, opts) do
    case load_resource(rt, rid, opts) do
      {:ok, resource} ->
        # Wrap the conversation + companion-row writes in a single transaction
        # so a failure on the second write does not leave an orphan
        # conversation. The unique-constraint race recovery runs *outside* the
        # transaction (the transaction itself returned `{:error, _}` already).
        result =
          Magus.Repo.transaction(fn ->
            with {:ok, conv} <- create_conversation_for(resource, rt, actor, opts),
                 {:ok, link} <- create_companion_row(rt, rid, conv.id, opts) do
              {conv, link}
            else
              {:error, reason} -> Magus.Repo.rollback(reason)
            end
          end)

        case result do
          {:ok, {conv, link}} ->
            Logger.info("companion: created",
              resource_type: rt,
              resource_id: rid,
              conversation_id: conv.id,
              user_id: actor.id
            )

            load_with_conversation(link, opts)

          {:error, %Ash.Error.Invalid{errors: errors} = err} ->
            if unique_constraint_error?(errors) do
              # Concurrent caller won the unique-constraint race. Re-read.
              case Chat.get_companion_by_resource(rt, rid, opts) do
                {:ok, link} ->
                  load_with_conversation(link, opts)

                _ ->
                  {:error, err}
              end
            else
              # Non-race validation failure (e.g. ActorOwnsConversation, or
              # any future validation). Surface it instead of swallowing.
              Logger.warning("companion: create failed",
                resource_type: rt,
                resource_id: rid,
                user_id: actor.id,
                error: inspect(err)
              )

              {:error, err}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, _} = err ->
        err
    end
  end

  defp load_resource(:file, id, opts), do: Magus.Files.get_file(id, opts)

  # A brain page has no workspace_id of its own; it inherits its brain's. Load
  # the brain so the companion conversation lands in the same workspace as the
  # brain (companion chat, brain, and agent then all operate in one workspace).
  defp load_resource(:brain_page, id, opts),
    do: Magus.Brain.get_page(id, Keyword.put(opts, :load, [:brain]))

  defp create_conversation_for(resource, rt, actor, opts) do
    title = "About: #{resource_display_name(resource, rt)}"
    workspace_id = resource_workspace_id(resource, rt)
    custom_agent_id = resolve_default_agent_id(workspace_id, actor)

    attrs =
      %{
        title: title,
        workspace_id: workspace_id,
        custom_agent_id: custom_agent_id
      }
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    Chat.create_conversation(attrs, opts)
  end

  defp resolve_default_agent_id(workspace_id, actor) when is_binary(workspace_id) do
    case Magus.Agents.ensure_workspace_default_agent(workspace_id, actor) do
      {:ok, agent} -> agent.id
      _ -> nil
    end
  end

  defp resolve_default_agent_id(_workspace_id, actor) do
    case Magus.Agents.ensure_default_agent(actor) do
      {:ok, agent} -> agent.id
      _ -> nil
    end
  end

  defp create_companion_row(rt, rid, conv_id, opts) do
    Ash.create(
      ConversationCompanion,
      %{resource_type: rt, resource_id: rid, conversation_id: conv_id},
      opts
    )
  end

  # A file carries its own workspace_id; a brain page inherits its brain's (a
  # page has no workspace_id attribute, so `Map.get(page, :workspace_id)` used to
  # silently return nil and drop the companion into the personal workspace).
  defp resource_workspace_id(%{workspace_id: ws}, :file), do: ws
  defp resource_workspace_id(%{brain: %{workspace_id: ws}}, :brain_page), do: ws
  defp resource_workspace_id(_resource, _rt), do: nil

  defp resource_display_name(%{name: name}, :file) when is_binary(name), do: name
  defp resource_display_name(%{title: t}, :brain_page) when is_binary(t) and t != "", do: t
  defp resource_display_name(_, :brain_page), do: "Untitled page"
  defp resource_display_name(_, :file), do: "Untitled file"

  defp load_with_conversation(link, opts) do
    Ash.load(link, [:conversation], opts)
  end

  # Recognises a unique-identity violation from either of this resource's
  # identities (`:unique_companion_per_resource` or `:unique_conversation`).
  # Ash surfaces these as `Ash.Error.Changes.InvalidAttribute` (or
  # `InvalidChanges`) with the default "has already been taken" message.
  defp unique_constraint_error?(errors) when is_list(errors) do
    Enum.any?(errors, fn
      %Ash.Error.Changes.InvalidAttribute{field: field, message: msg}
      when field in [:conversation_id, :resource_id, :user_id] and is_binary(msg) ->
        String.contains?(msg, "has already been taken")

      %Ash.Error.Changes.InvalidChanges{message: msg} when is_binary(msg) ->
        String.contains?(msg, "has already been taken") or
          String.contains?(msg, "unique") or
          String.contains?(msg, "already exists")

      %{errors: nested} when is_list(nested) ->
        unique_constraint_error?(nested)

      _ ->
        false
    end)
  end

  defp unique_constraint_error?(_), do: false
end
