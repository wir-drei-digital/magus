defmodule Magus.SuperBrain.GraphRouter do
  @moduledoc """
  Pure function mapping (resource, ownership, context) to a FalkorDB graph name.

  Authorization is by graph name. This module is the single source of truth
  for the naming convention. If two actors resolve to the same graph name,
  they can read the same data; if not, they are isolated.
  """

  @type resource ::
          {:brain_page, brain_id :: String.t(), page_id :: String.t()}
          | {:brain_source, brain_id :: String.t(), source_id :: String.t()}
          | {:memory, user_id :: String.t(), :personal | {:workspace, String.t()}}
          | {:file, user_id :: String.t(), :personal | {:workspace, String.t()}}
          | {:file_chunk, user_id :: String.t(), :personal | {:workspace, String.t()}}
          | {:draft, user_id :: String.t(), any()}

  @spec graph_for(resource, any()) :: {:ok, String.t()} | {:error, term()}
  def graph_for({:brain_page, brain_id, _page_id}, _actor),
    do: {:ok, "brain:#{brain_id}"}

  def graph_for({:brain_source, brain_id, _source_id}, _actor),
    do: {:ok, "brain:#{brain_id}"}

  def graph_for({:memory, user_id, :personal}, _),
    do: {:ok, "memories:user:#{user_id}"}

  def graph_for({:memory, _user_id, {:workspace, ws_id}}, _),
    do: {:ok, "memories:workspace:#{ws_id}"}

  def graph_for({:file, user_id, :personal}, _),
    do: {:ok, "files:user:#{user_id}"}

  def graph_for({:file, _user_id, {:workspace, ws_id}}, _),
    do: {:ok, "files:workspace:#{ws_id}"}

  def graph_for({:file_chunk, user_id, :personal}, _),
    do: {:ok, "files:user:#{user_id}"}

  def graph_for({:file_chunk, _user_id, {:workspace, ws_id}}, _),
    do: {:ok, "files:workspace:#{ws_id}"}

  def graph_for({:draft, user_id, _context}, _),
    do: {:ok, "drafts:user:#{user_id}"}

  def graph_for(other, _), do: {:error, {:unrouteable, other}}
end
