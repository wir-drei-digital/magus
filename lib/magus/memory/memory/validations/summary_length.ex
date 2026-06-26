defmodule Magus.Memory.Memory.Validations.SummaryLength do
  @moduledoc """
  Validates that the memory summary doesn't exceed the maximum character limit.

  The limit is read from config `:magus, Magus.Memory, :max_summary_chars` with
  a default of 500 characters.
  """

  use Ash.Resource.Validation

  @impl true
  def init(opts) do
    {:ok, opts}
  end

  @impl true
  def validate(changeset, opts, _context) do
    config_max = Application.get_env(:magus, Magus.Memory, [])[:max_summary_chars]
    max_chars = Keyword.get(opts, :max_chars, config_max || 500)
    summary = Ash.Changeset.get_attribute(changeset, :summary)

    if summary && String.length(summary) > max_chars do
      {:error,
       field: :summary,
       message: "Summary too long (#{String.length(summary)} chars, max #{max_chars})."}
    else
      :ok
    end
  end
end
