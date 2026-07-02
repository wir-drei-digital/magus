defmodule Magus.Organizations.Checks.ActorIsSystem do
  @moduledoc """
  Policy check: the actor is the internal `Magus.SystemActor` marker struct.

  Authorizes cross-boundary machine writes (cloud billing -> core resources)
  that previously relied on `authorize_if always()` bypasses. Human actors
  never match; internal call sites either pass `actor: %Magus.SystemActor{}`
  or `authorize?: false`.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "actor is the internal system actor"

  @impl true
  def match?(%Magus.SystemActor{}, _context, _opts), do: true
  def match?(_actor, _context, _opts), do: false
end
