defmodule Magus.Organizations.OrganizationMember.Validations.ValidTransferTarget do
  @moduledoc """
  Guards `:transfer_ownership`. Ownership may only move to an active member,
  and never to the acting owner themselves. Reads the record under change
  (`changeset.data`) as the transfer target.
  """
  use Ash.Resource.Validation

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, context) do
    target = changeset.data
    actor_id = context.actor && context.actor.id

    cond do
      target.status != :active ->
        {:error, field: :status, message: "ownership can only transfer to an active member"}

      actor_id && target.user_id == actor_id ->
        {:error, field: :user_id, message: "you already own this organization"}

      true ->
        :ok
    end
  end
end
