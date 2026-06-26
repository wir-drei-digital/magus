defmodule Magus.Repo.Migrations.ConvertDraftContentToJsonb do
  @moduledoc """
  Converts the drafts.content column from text (markdown) to jsonb (ProseMirror JSON).

  Existing markdown content is converted to ProseMirror JSON inline.
  """

  use Ecto.Migration

  alias Magus.Drafts.ProseMirrorConverter

  @default_doc Jason.encode!(%{"type" => "doc", "content" => [%{"type" => "paragraph"}]})

  def up do
    # Step 1: Add a temporary jsonb column
    alter table(:drafts) do
      add :content_jsonb, :map
    end

    flush()

    # Step 2: Convert existing markdown content to ProseMirror JSON
    execute(fn ->
      repo().query!("SELECT id, content FROM drafts", [])
      |> Map.get(:rows)
      |> Enum.each(fn [id, markdown_content] ->
        json_doc =
          case ProseMirrorConverter.from_markdown(markdown_content || "") do
            {:ok, doc} -> doc
            {:error, _} -> %{"type" => "doc", "content" => [%{"type" => "paragraph"}]}
          end

        repo().query!(
          "UPDATE drafts SET content_jsonb = $1 WHERE id = $2",
          [json_doc, id]
        )
      end)
    end)

    # Step 3: Also convert paper trail versions
    # The versions table stores content in the `changes` jsonb column under the "content" key
    execute(fn ->
      repo().query!("SELECT id, changes FROM drafts_versions WHERE changes ? 'content'", [])
      |> Map.get(:rows)
      |> Enum.each(fn [id, changes] ->
        markdown_content = changes["content"]

        if is_binary(markdown_content) do
          json_doc =
            case ProseMirrorConverter.from_markdown(markdown_content) do
              {:ok, doc} -> doc
              {:error, _} -> %{"type" => "doc", "content" => [%{"type" => "paragraph"}]}
            end

          updated_changes = Map.put(changes, "content", json_doc)

          repo().query!(
            "UPDATE drafts_versions SET changes = $1 WHERE id = $2",
            [updated_changes, id]
          )
        end
      end)
    end)

    # Step 4: Drop old text column, rename new jsonb column
    alter table(:drafts) do
      remove :content
    end

    rename table(:drafts), :content_jsonb, to: :content

    flush()

    # Step 5: Set NOT NULL and default
    alter table(:drafts) do
      modify :content, :map, null: false, default: fragment("'#{@default_doc}'::jsonb")
    end
  end

  def down do
    # Reverse: convert jsonb back to text
    alter table(:drafts) do
      add :content_text, :text
    end

    flush()

    execute(fn ->
      repo().query!("SELECT id, content FROM drafts", [])
      |> Map.get(:rows)
      |> Enum.each(fn [id, json_content] ->
        markdown =
          if is_map(json_content) do
            ProseMirrorConverter.to_markdown(json_content)
          else
            ""
          end

        repo().query!(
          "UPDATE drafts SET content_text = $1 WHERE id = $2",
          [markdown, id]
        )
      end)
    end)

    alter table(:drafts) do
      remove :content
    end

    rename table(:drafts), :content_text, to: :content

    flush()

    alter table(:drafts) do
      modify :content, :text, null: false, default: ""
    end
  end
end
