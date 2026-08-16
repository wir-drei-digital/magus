defmodule Magus.Accounts.UnconfirmedRetention do
  @moduledoc """
  Reaps password-signup accounts that never confirmed their email
  (spec: signup-abuse-hardening, section C). v1 deliberately reaps ONLY
  users with no owned structure or content: org owners, sole-admin
  workspace holders (magus-xjc3 tracks proper teardown for both), and
  anyone owning a file, brain resource, or a conversation with a
  complete agent REPLY (message_type `:message`, not an `:event` block
  notice — see `owns_conversations?/1`) are all skipped with a warning.
  All internal lookups run authorize?: false: there is no actor in the
  Oban context and user-facing policies would hide exactly the rows we
  check.

  ## What actually protects data here

  `AccountDeletion.execute/2`'s conditional final-row DELETE (see that
  module's docs) protects ONLY the `users` row, inside its own
  transaction. `AccountDeletion.cleanup_external_resources/1` — files +
  S3, conversation hard-deletion, Super Brain graph purges — runs BEFORE
  that transaction even opens, so nothing about the transaction (rollback
  included) can undo it. Two things stand between a reap candidate and
  losing real content, neither of which is "the transaction rolls back":

    1. `owns_content?/1` below: a user who owns a file, brain resource, or
       a conversation containing at least one COMPLETE agent REPLY is
       never handed to `AccountDeletion.execute/2` with
       `require_unconfirmed: true` in the first place. Conversation
       ownership is deliberately narrower than "owns a conversation row":
       the confirmation gate's own SPA flow creates the conversation
       BEFORE the first message is sent, then blocks the turn, so an
       unconfirmed user who merely attempted to chat owns a conversation
       holding only their own blocked user message. Treating that alone
       as protected content would make the reaper's primary target
       population — bots that attempted chat and got blocked —
       permanently unreapable. Naively checking role `:agent` +
       status `:complete` is NOT enough to distinguish a real reply from
       this: the gate's own block notice
       (`Magus.Agents.Plugins.Support.ErrorMessages.create_error_event/3`)
       is ALSO role `:agent` + status `:complete` — it just carries
       `message_type: :event` instead of the `:message` a genuine reply
       gets. `owns_conversations?/1` filters on all three attributes for
       exactly this reason. A conversation with a real agent reply
       (role `:agent`, message_type `:message`, status `:complete`) is
       real content and still blocks the reap.
    2. `AccountDeletion.execute/2`'s fresh `confirmed_at` re-check,
       performed immediately before `cleanup_external_resources/1` runs.
       This narrows the race to the gap between that read and the
       external cleanup call (typically sub-millisecond) — it does not
       close it. The residual risk requires the user to both confirm AND
       create reapable content inside that gap.
  """

  require Ash.Query
  require Logger

  import Ecto.Query

  alias Magus.Accounts.AccountDeletion
  alias Magus.Accounts.User
  alias Magus.Repo

  @spec ttl_days() :: pos_integer() | nil
  def ttl_days, do: Application.get_env(:magus, :unconfirmed_account_ttl_days)

  @spec validate_config!() :: :ok
  def validate_config! do
    case ttl_days() do
      nil ->
        :ok

      days when is_integer(days) and days >= 1 ->
        :ok

      other ->
        raise "unconfirmed_account_ttl_days must be nil or an integer >= 1 " <>
                "(the reaper's scheduler floor is 1 day), got: #{inspect(other)}"
    end
  end

  @doc """
  Reaps `user` if it is an unconfirmed, past-TTL, structure-and-content-free
  account.

  Returns `:deleted` when the account was hard-deleted, `:skipped` when a
  guard (owned structure/content, or the precondition checks inside
  `AccountDeletion`) refused the delete, and `:noop` when the account
  simply isn't a reap candidate (confirmed, too young, or TTL disabled).

  Checks `ttl_days/0` before doing anything else — including before the
  reload below — so a disabled instance (`nil`, the core default) never
  pays for a DB read per candidate row the scheduler hands it.

  Reloads `user` from the DB before evaluating confirmed_at/TTL/ownership:
  the AshOban trigger's own `worker_read_action` already does this
  immediately before invoking the action this function backs, so in
  production `user` is already fresh; reloading here is defensive (matters
  for direct callers, e.g. tests) and cheap relative to everything after
  it. This is an advisory freshness improvement, not itself a race
  guarantee — see the moduledoc for what actually is.
  """
  @spec reap(User.t()) :: :deleted | :skipped | :noop
  def reap(user) do
    case ttl_days() do
      nil ->
        :noop

      days ->
        case reload(user) do
          # The row is gone — deleted by something else between the
          # worker's own read and this call. Nothing to reap.
          nil -> :noop
          reloaded -> do_reap(reloaded, days)
        end
    end
  end

  defp do_reap(user, days) do
    cond do
      not is_nil(user.confirmed_at) ->
        :noop

      not past_ttl?(user, days) ->
        :noop

      owns_structure_or_content?(user) ->
        Logger.warning(
          "skipping reap of #{user.id}: owns an organization, is sole workspace admin, " <>
            "or owns a file/conversation/brain resource"
        )

        :skipped

      true ->
        delete_if_still_unconfirmed(user)
    end
  end

  # Ash.reload!/2 raises Ash.Error.Invalid (wrapping the underlying
  # Ash.Error.Query.NotFound) rather than the NotFound error itself, so
  # rescuing Ash.Error.Query.NotFound around the bang version is dead code.
  # The non-bang version returns a plain {:error, _} instead.
  defp reload(user) do
    case Ash.reload(user, authorize?: false) do
      {:ok, reloaded} -> reloaded
      {:error, _} -> nil
    end
  end

  defp delete_if_still_unconfirmed(user) do
    case AccountDeletion.execute(user, require_unconfirmed: true) do
      :ok ->
        Logger.info("reaped unconfirmed account #{user.id}")
        :deleted

      {:error, reason} ->
        Logger.warning("reap of #{user.id} did not delete: #{inspect(reason)}")
        :skipped
    end
  end

  defp past_ttl?(user, days) do
    DateTime.compare(
      user.inserted_at,
      DateTime.add(DateTime.utc_now(), -days * 86_400, :second)
    ) == :lt
  end

  defp owns_structure_or_content?(user) do
    owns_org?(user) or sole_admin_of_any_workspace?(user) or owns_content?(user)
  end

  defp owns_org?(user) do
    Repo.exists?(from(o in "organizations", where: o.owner_id == type(^user.id, :binary_id)))
  end

  defp sole_admin_of_any_workspace?(user) do
    AccountDeletion.sole_admin_workspace_ids(user) != []
  end

  # Mirrors what AccountDeletion.cleanup_external_resources/1 destroys
  # BEFORE opening a transaction: files (+ S3), conversations, and — via
  # Magus.SuperBrain.Cleanup.purge_user/1 — the Super Brain graphs derived
  # from a user's brain pages. None of that is protected by a rolled-back
  # transaction (see the moduledoc), so a user who owns any of it must
  # never reach AccountDeletion.execute/2 as a reap candidate at all.
  defp owns_content?(user) do
    owns_files?(user) or owns_conversations?(user) or owns_brain_resources?(user)
  end

  defp owns_files?(user) do
    Magus.Files.File
    |> Ash.Query.filter(user_id == ^user.id)
    |> Ash.exists?(authorize?: false)
  end

  defp owns_conversations?(user) do
    # Matches AccountDeletion's own cleanup_user_conversation_external_resources/1
    # filter (only non-soft-deleted conversations are destroyed by that
    # pre-transaction cleanup pass), refined by one more condition: the
    # conversation must hold at least one COMPLETE agent reply (role
    # :agent, status :complete — see Magus.Chat.Message). The confirmation
    # gate itself creates the conversation before the first message is
    # sent, so an unconfirmed user who merely tried to chat (and got
    # blocked) owns a conversation containing only their own blocked user
    # message — that is not real content worth protecting, and without
    # this refinement it would make the reaper's primary target
    # population (bots that attempted chat) permanently unreapable. A
    # conversation with a real agent reply is real content and still
    # blocks the reap.
    #
    # message_type == :message is load-bearing, not incidental: the gate's
    # OWN block notice is itself a role: :agent, status: :complete message
    # (Magus.Agents.Plugins.Support.ErrorMessages.create_error_event/3, via
    # Message's :create_event action) — but with message_type: :event, not
    # :message. Without this extra condition, the very notice that tells
    # the user "confirm your email to chat" would count as the "real agent
    # reply" that protects the conversation, defeating this whole
    # refinement for exactly the population it targets. Genuine agent
    # replies (Message's :upsert_response action) default message_type to
    # :message (the attribute's schema default) and are unaffected.
    Magus.Chat.Conversation
    |> Ash.Query.filter(
      user_id == ^user.id and is_nil(deleted_at) and
        exists(messages, role == :agent and message_type == :message and status == :complete)
    )
    |> Ash.exists?(authorize?: false)
  end

  defp owns_brain_resources?(user) do
    Magus.Brain.BrainResource
    |> Ash.Query.filter(user_id == ^user.id)
    |> Ash.exists?(authorize?: false)
  end
end
