defmodule Magus.Checks.IsAiAgent do
  @moduledoc """
  Shared policy check that authorizes the AiAgent actor.

  This is used for background system operations like memory extraction
  that need to access/modify resources without a user context.
  """

  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts) do
    "actor is an AI agent"
  end

  @impl true
  def match?(%Magus.Agents.Support.AiAgent{}, _context, _opts), do: true
  def match?(_, _context, _opts), do: false
end
