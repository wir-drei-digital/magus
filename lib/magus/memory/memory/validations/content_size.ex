defmodule Magus.Memory.Memory.Validations.ContentSize do
  @moduledoc """
  Validates that the memory content doesn't exceed the maximum character limit.

  The limit is read from config `:magus, Magus.Memory, :max_content_chars` with
  a default of 8,000 characters.
  """

  use Ash.Resource.Validation

  @impl true
  def init(opts) do
    {:ok, opts}
  end

  @impl true
  def validate(changeset, opts, _context) do
    config_max = Application.get_env(:magus, Magus.Memory, [])[:max_content_chars]
    max_chars = Keyword.get(opts, :max_chars, config_max || 8_000)
    content = Ash.Changeset.get_attribute(changeset, :content)

    if content do
      content_string = Jason.encode!(content)
      char_count = String.length(content_string)

      if char_count > max_chars do
        {:error,
         field: :content,
         message:
           "Content too large (#{char_count} chars, max #{max_chars}). Summarize or split into multiple memories."}
      else
        :ok
      end
    else
      :ok
    end
  end
end
