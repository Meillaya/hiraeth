defmodule Hiraeth.Repo.Migrations.AddSourceSnapshotRetentionMetadata do
  use Ecto.Migration

  def change do
    alter table(:source_snapshots) do
      add :provider, :text
      add :source_url, :text
      add :checksum, :text
      add :http_metadata, :map, null: false, default: %{}
      add :adapter_version, :text
      add :source_mode, :text
      add :artifact_path, :text
    end

    create index(:source_snapshots, [:provider], name: "source_snapshots_provider_index")
    create index(:source_snapshots, [:source_url], name: "source_snapshots_source_url_index")
    create index(:source_snapshots, [:checksum], name: "source_snapshots_checksum_index")

    create constraint(:source_snapshots, :source_snapshots_source_mode_check,
             check:
               "source_mode IS NULL OR source_mode IN ('api', 'scrape', 'manifest', 'manual')"
           )
  end
end
