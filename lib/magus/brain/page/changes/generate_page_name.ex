defmodule Magus.Brain.Page.Changes.GeneratePageName do
  @moduledoc """
  Ash change module that derives a page title from its markdown body.

  Phase C7: parses the first H1 (`# Heading`) line out of `page.body`,
  skipping any leading YAML frontmatter block. The H1 becomes the new
  title via `Magus.Brain.update_page_title/2`.

  The change is a no-op when:

    * the page already has a non-nil `:title` (the user / a previous
      pass has set one),
    * the body is `nil` or empty (Phase B coexistence-window race
      where the row exists but `update_body` hasn't fired yet — the
      next cron tick will retry once content lands), or
    * the body has no H1 heading at all.

  No-op cases leave the changeset untouched; the parent action returns
  the page with `title: nil` and `needs_title` keeps the cron firing
  on subsequent ticks. This matches the previous block-based behavior
  except that "no content" no longer materializes a synthetic
  "Untitled" title that would break the auto-naming loop.
  """

  use Ash.Resource.Change
  require Logger

  alias Magus.Brain.Frontmatter

  @impl true
  def change(changeset, _opts, _context) do
    page = changeset.data

    cond do
      not is_nil(page.title) ->
        Logger.debug("GeneratePageName: skipping page #{page.id} (title already set)")
        changeset

      is_nil(page.body) or page.body == "" ->
        Logger.debug("GeneratePageName: skipping page #{page.id} (body empty)")
        changeset

      true ->
        case extract_h1(page.body) do
          nil ->
            Logger.debug("GeneratePageName: page #{page.id} has no H1, skipping")
            changeset

          title ->
            Logger.info("GeneratePageName: setting title for page #{page.id}: #{inspect(title)}")
            Ash.Changeset.force_change_attribute(changeset, :title, title)
        end
    end
  end

  # Strips any leading YAML frontmatter block, then scans for the first
  # markdown H1 line (`# Heading`). Returns the heading text trimmed of
  # whitespace, or nil when no H1 is present. Malformed frontmatter is
  # treated as no-frontmatter — we still try to find an H1 in the raw
  # body rather than failing the trigger.
  defp extract_h1(body) do
    {_matter, rest} = Frontmatter.parse(body)

    rest
    |> String.split(["\r\n", "\n"])
    |> Enum.find_value(fn line ->
      case Regex.run(~r/^#\s+(.+?)\s*$/, line) do
        [_, title] -> String.trim(title)
        _ -> nil
      end
    end)
    |> case do
      nil -> nil
      "" -> nil
      title -> title
    end
  end
end
