defmodule Hiraeth.Repo.Migrations.AddPublicCatalogSearchIndexes do
  use Ecto.Migration

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")

    execute("""
    CREATE INDEX source_records_public_catalog_isbn_expr_index
    ON source_records ((coalesce(raw_payload->'edition'->>'isbn_13', raw_payload->'identifier'->>'isbn_13')))
    """)

    execute("""
    CREATE INDEX works_public_catalog_title_trgm_index
    ON works USING gin ((lower(coalesce(title, ''))) gin_trgm_ops)
    """)

    execute("""
    CREATE INDEX works_public_catalog_subtitle_trgm_index
    ON works USING gin ((lower(coalesce(subtitle, ''))) gin_trgm_ops)
    """)

    execute("""
    CREATE INDEX editions_public_catalog_title_trgm_index
    ON editions USING gin ((lower(coalesce(title, ''))) gin_trgm_ops)
    """)

    execute("""
    CREATE INDEX editions_public_catalog_subtitle_trgm_index
    ON editions USING gin ((lower(coalesce(subtitle, ''))) gin_trgm_ops)
    """)

    execute("""
    CREATE INDEX publishers_public_catalog_name_trgm_index
    ON publishers USING gin ((lower(coalesce(name, ''))) gin_trgm_ops)
    """)

    execute("""
    CREATE INDEX contributors_public_catalog_display_name_trgm_index
    ON contributors USING gin ((lower(coalesce(display_name, ''))) gin_trgm_ops)
    """)

    execute("""
    CREATE INDEX series_public_catalog_title_trgm_index
    ON series USING gin ((lower(coalesce(title, ''))) gin_trgm_ops)
    """)

    execute("""
    CREATE INDEX identifiers_public_catalog_normalized_value_trgm_index
    ON identifiers USING gin ((regexp_replace(coalesce(value, ''), '[^0-9xX]', '', 'g')) gin_trgm_ops)
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS identifiers_public_catalog_normalized_value_trgm_index")
    execute("DROP INDEX IF EXISTS series_public_catalog_title_trgm_index")
    execute("DROP INDEX IF EXISTS contributors_public_catalog_display_name_trgm_index")
    execute("DROP INDEX IF EXISTS publishers_public_catalog_name_trgm_index")
    execute("DROP INDEX IF EXISTS editions_public_catalog_subtitle_trgm_index")
    execute("DROP INDEX IF EXISTS editions_public_catalog_title_trgm_index")
    execute("DROP INDEX IF EXISTS works_public_catalog_subtitle_trgm_index")
    execute("DROP INDEX IF EXISTS works_public_catalog_title_trgm_index")
    execute("DROP INDEX IF EXISTS source_records_public_catalog_isbn_expr_index")
  end
end
