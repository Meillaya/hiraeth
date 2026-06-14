defmodule Hiraeth.Repo.Migrations.AddIndexedPublicCatalogFacets do
  use Ecto.Migration

  def up do
    execute("""
    CREATE INDEX editions_public_catalog_format_lower_index
    ON editions ((lower(coalesce(format, ''))))
    """)

    execute("""
    CREATE INDEX editions_public_catalog_language_lower_index
    ON editions ((lower(coalesce(language_code, ''))))
    """)

    execute("""
    CREATE INDEX editions_public_catalog_published_year_index
    ON editions ((extract(year from published_on)::int))
    """)

    execute("""
    CREATE INDEX editions_public_catalog_published_on_index
    ON editions (published_on DESC NULLS LAST)
    """)

    execute("""
    CREATE INDEX works_public_catalog_original_language_lower_index
    ON works ((lower(coalesce(original_language_code, ''))))
    """)

    execute("""
    CREATE INDEX works_public_catalog_subjects_gin_index
    ON works USING gin (subjects)
    """)

    execute("""
    CREATE INDEX works_public_catalog_title_sort_index
    ON works ((lower(title)))
    """)

    execute("""
    CREATE INDEX contributions_public_catalog_role_work_index
    ON contributions (role, work_id)
    """)

    execute("""
    CREATE INDEX contributions_public_catalog_role_edition_index
    ON contributions (role, edition_id)
    """)

    execute("""
    CREATE INDEX source_records_public_catalog_imported_at_index
    ON source_records (imported_at DESC NULLS LAST)
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS source_records_public_catalog_imported_at_index")
    execute("DROP INDEX IF EXISTS contributions_public_catalog_role_edition_index")
    execute("DROP INDEX IF EXISTS contributions_public_catalog_role_work_index")
    execute("DROP INDEX IF EXISTS works_public_catalog_title_sort_index")
    execute("DROP INDEX IF EXISTS works_public_catalog_subjects_gin_index")
    execute("DROP INDEX IF EXISTS works_public_catalog_original_language_lower_index")
    execute("DROP INDEX IF EXISTS editions_public_catalog_published_on_index")
    execute("DROP INDEX IF EXISTS editions_public_catalog_published_year_index")
    execute("DROP INDEX IF EXISTS editions_public_catalog_language_lower_index")
    execute("DROP INDEX IF EXISTS editions_public_catalog_format_lower_index")
  end
end
