defmodule Hiraeth.Repo.Migrations.AddSourceRecordIdentityAndEditionLink do
  use Ecto.Migration

  def up do
    alter table(:source_records) do
      add :source_identity, :text

      add :edition_id,
          references(:editions,
            column: :id,
            name: "source_records_edition_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :nilify_all
          )
    end

    execute("""
    UPDATE source_records
    SET source_identity = coalesce(
      raw_payload->>'source_identity',
      raw_payload->'identifier'->>'source_identity',
      raw_payload->'edition'->>'isbn_13',
      raw_payload->'identifier'->>'isbn_13'
    )
    WHERE source_identity IS NULL
    """)

    execute("""
    UPDATE source_records sr
    SET edition_id = i.edition_id
    FROM identifiers i
    WHERE sr.edition_id IS NULL
      AND i.value = coalesce(
        sr.raw_payload->>'source_identity',
        sr.raw_payload->'identifier'->>'source_identity',
        sr.raw_payload->'edition'->>'isbn_13',
        sr.raw_payload->'identifier'->>'isbn_13'
      )
      AND i.identifier_type IN ('isbn_13', 'source_record')
    """)

    create index(:source_records, [:edition_id],
             name: "source_records_public_catalog_edition_id_index"
           )

    create index(:source_records, [:source_identity],
             name: "source_records_public_catalog_source_identity_index"
           )
  end

  def down do
    drop_if_exists index(:source_records, [:source_identity],
                     name: "source_records_public_catalog_source_identity_index"
                   )

    drop_if_exists index(:source_records, [:edition_id],
                     name: "source_records_public_catalog_edition_id_index"
                   )

    drop constraint(:source_records, "source_records_edition_id_fkey")

    alter table(:source_records) do
      remove :edition_id
      remove :source_identity
    end
  end
end
