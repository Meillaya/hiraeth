defmodule Hiraeth.Repo.Migrations.DropImportsCsvWorkflowTables do
  use Ecto.Migration

  # The Imports CSV workflow (staged rows, column mappings, review items) was deleted
  # with its Ash resources. `import_runs` stays: ingestion apply/tombstone phases and
  # `source_records.import_run_id` keep live provenance lineage through it.

  def up do
    execute "ALTER TABLE IF EXISTS review_items DROP CONSTRAINT IF EXISTS review_items_staged_import_row_id_fkey"

    execute "ALTER TABLE IF EXISTS review_items DROP CONSTRAINT IF EXISTS review_items_import_run_id_fkey"

    drop_if_exists unique_index(:review_items, [:import_run_id, :entity_type, :id],
                     name: "review_items_unique_review_item_index"
                   )

    drop_if_exists table(:review_items)

    execute "ALTER TABLE IF EXISTS staged_import_rows DROP CONSTRAINT IF EXISTS staged_import_rows_import_run_id_fkey"

    drop_if_exists unique_index(:staged_import_rows, [:import_run_id, :row_number],
                     name: "staged_import_rows_unique_import_row_index"
                   )

    drop_if_exists table(:staged_import_rows)

    execute "ALTER TABLE IF EXISTS import_mappings DROP CONSTRAINT IF EXISTS import_mappings_import_run_id_fkey"

    drop_if_exists unique_index(:import_mappings, [:import_run_id, :source_column, :target_field],
                     name: "import_mappings_unique_import_mapping_index"
                   )

    drop_if_exists table(:import_mappings)
  end

  def down do
    :ok
  end
end
