defmodule Magus.Repo.Migrations.AddModelDescriptionTranslations do
  @moduledoc """
  Adds JSONB translation fields for model descriptions to support multiple languages.
  Migrates existing English descriptions to the new format.
  """

  use Ecto.Migration

  def up do
    alter table(:models) do
      add :short_description_translations, :map, null: false, default: %{}
      add :detailed_description_translations, :map, null: false, default: %{}
    end

    # Migrate existing descriptions to English translations
    execute """
    UPDATE models
    SET short_description_translations = jsonb_build_object('en', short_description)
    WHERE short_description IS NOT NULL
    """

    execute """
    UPDATE models
    SET detailed_description_translations = jsonb_build_object('en', detailed_description)
    WHERE detailed_description IS NOT NULL
    """
  end

  def down do
    alter table(:models) do
      remove :detailed_description_translations
      remove :short_description_translations
    end
  end
end
