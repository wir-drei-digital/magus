defmodule Magus.Brain.Topics do
  @moduledoc """
  Centralized PubSub topic names for brain real-time events.
  """

  @doc "Brain-level topic for brain-wide events (page created, access changes)."
  def brain(brain_id), do: "brain:#{brain_id}"

  @doc "Page-level topic for page-specific events (block changes, presence)."
  def page(brain_id, page_id), do: "brain:#{brain_id}:page:#{page_id}"
end
