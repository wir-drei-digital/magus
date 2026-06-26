defmodule Magus.Brain.Page.Calculations.Prosemirror do
  @moduledoc """
  Calculates a page's body as a ProseMirror JSON document (frontmatter
  stripped), so the editor can hydrate from JSON instead of parsing markdown
  client-side. Mirrors how the Draft resource serves its `content` JSON.
  """
  use Ash.Resource.Calculation
  alias Magus.Brain.ProseMirrorProfile

  @impl true
  def load(_query, _opts, _context), do: [:body]

  @impl true
  def calculate(records, _opts, _context) do
    Enum.map(records, fn page ->
      ProseMirrorProfile.body_to_prosemirror(page.body)
    end)
  end
end
