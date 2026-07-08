defmodule Hiraeth.Repo.Migrations.AddCurationOverridesSourceRecordIndex do
  use Ecto.Migration

  def change do
    create index(:curation_overrides, [:source_record_id],
             name: "curation_overrides_source_record_id_index"
           )
  end
end
