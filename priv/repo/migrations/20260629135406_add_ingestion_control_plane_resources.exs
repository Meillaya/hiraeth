defmodule Hiraeth.Repo.Migrations.AddIngestionControlPlaneResources do
  use Ecto.Migration

  def change do
    create table(:provider_sources, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :stable_source_key, :text, null: false
      add :provider_name, :text, null: false
      add :source_kind, :text, null: false
      add :ingestion_mode, :text, null: false
      add :base_uri, :text
      add :manifest_uri, :text
      add :allowed_hosts, {:array, :text}, null: false, default: []
      add :rate_limit_per_minute, :bigint
      add :max_bytes, :bigint
      add :checksum_algorithm, :text
      add :required_checksum, :text
      add :license_note, :text
      add :enabled?, :boolean, null: false, default: false
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create unique_index(:provider_sources, [:stable_source_key],
             name: "provider_sources_unique_stable_source_key_index"
           )

    create index(:provider_sources, [:source_kind], name: "provider_sources_source_kind_index")

    create index(:provider_sources, [:ingestion_mode],
             name: "provider_sources_ingestion_mode_index"
           )

    create index(:provider_sources, [:enabled?], name: "provider_sources_enabled_index")

    create constraint(:provider_sources, :provider_sources_source_kind_check,
             check: "source_kind IN ('publisher', 'bookstore', 'distributor', 'manual')"
           )

    create constraint(:provider_sources, :provider_sources_ingestion_mode_check,
             check: "ingestion_mode IN ('manifest', 'scrape', 'api', 'manual')"
           )

    create constraint(:provider_sources, :provider_sources_rate_limit_positive_check,
             check: "rate_limit_per_minute IS NULL OR rate_limit_per_minute >= 1"
           )

    create constraint(:provider_sources, :provider_sources_max_bytes_positive_check,
             check: "max_bytes IS NULL OR max_bytes >= 1"
           )

    create table(:provider_runs, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true

      add :provider_source_id,
          references(:provider_sources,
            column: :id,
            name: "provider_runs_provider_source_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :delete_all
          ),
          null: false

      add :status, :text, null: false, default: "queued"
      add :requested_by, :text
      add :run_key, :text, null: false
      add :provenance, :map, null: false, default: %{}
      add :started_at, :utc_datetime
      add :finished_at, :utc_datetime
      add :source_count, :bigint, null: false, default: 0
      add :snapshot_count, :bigint, null: false, default: 0
      add :candidate_count, :bigint, null: false, default: 0
      add :accepted_count, :bigint, null: false, default: 0
      add :rejected_count, :bigint, null: false, default: 0
      add :error_count, :bigint, null: false, default: 0
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create unique_index(:provider_runs, [:provider_source_id, :run_key],
             name: "provider_runs_unique_provider_run_key_index"
           )

    create index(:provider_runs, [:provider_source_id],
             name: "provider_runs_provider_source_id_index"
           )

    create index(:provider_runs, [:status], name: "provider_runs_status_index")

    create index(:provider_runs, [:provider_source_id, :status],
             name: "provider_runs_source_status_index"
           )

    create constraint(:provider_runs, :provider_runs_status_check,
             check: "status IN ('queued', 'running', 'succeeded', 'failed', 'cancelled')"
           )

    create constraint(:provider_runs, :provider_runs_counts_nonnegative_check,
             check:
               "source_count >= 0 AND snapshot_count >= 0 AND candidate_count >= 0 AND accepted_count >= 0 AND rejected_count >= 0 AND error_count >= 0"
           )

    create table(:source_snapshots, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true

      add :provider_source_id,
          references(:provider_sources,
            column: :id,
            name: "source_snapshots_provider_source_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :delete_all
          ),
          null: false

      add :provider_run_id,
          references(:provider_runs,
            column: :id,
            name: "source_snapshots_provider_run_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :delete_all
          ),
          null: false

      add :source_uri, :text, null: false
      add :content_checksum, :text, null: false
      add :fetched_at, :utc_datetime, null: false
      add :http_status, :bigint
      add :content_type, :text
      add :byte_size, :bigint
      add :raw_payload, :map, null: false
      add :storage_ref, :text, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:source_snapshots, [:provider_source_id, :source_uri, :content_checksum],
             name: "source_snapshots_unique_source_snapshot_index"
           )

    create index(:source_snapshots, [:provider_source_id],
             name: "source_snapshots_provider_source_id_index"
           )

    create index(:source_snapshots, [:provider_run_id],
             name: "source_snapshots_provider_run_id_index"
           )

    create index(:source_snapshots, [:source_uri], name: "source_snapshots_source_uri_index")

    create index(:source_snapshots, [:content_checksum],
             name: "source_snapshots_content_checksum_index"
           )

    create constraint(:source_snapshots, :source_snapshots_http_status_check,
             check: "http_status IS NULL OR http_status BETWEEN 100 AND 599"
           )

    create constraint(:source_snapshots, :source_snapshots_byte_size_nonnegative_check,
             check: "byte_size IS NULL OR byte_size >= 0"
           )

    create table(:record_candidates, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true

      add :provider_run_id,
          references(:provider_runs,
            column: :id,
            name: "record_candidates_provider_run_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :delete_all
          ),
          null: false

      add :source_snapshot_id,
          references(:source_snapshots,
            column: :id,
            name: "record_candidates_source_snapshot_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :delete_all
          ),
          null: false

      add :candidate_identity, :text, null: false
      add :record_type, :text, null: false
      add :review_status, :text, null: false, default: "needs_review"
      add :source_uri, :text, null: false
      add :raw_metadata, :map, null: false
      add :normalized_metadata, :map, null: false
      add :validation_errors, {:array, :text}, null: false, default: []
      add :reviewer_note, :text
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create unique_index(:record_candidates, [:provider_run_id, :candidate_identity],
             name: "record_candidates_unique_record_candidate_index"
           )

    create index(:record_candidates, [:provider_run_id],
             name: "record_candidates_provider_run_id_index"
           )

    create index(:record_candidates, [:source_snapshot_id],
             name: "record_candidates_source_snapshot_id_index"
           )

    create index(:record_candidates, [:review_status],
             name: "record_candidates_review_status_index"
           )

    create index(:record_candidates, [:record_type], name: "record_candidates_record_type_index")

    create constraint(:record_candidates, :record_candidates_record_type_check,
             check: "record_type IN ('work', 'edition', 'contributor', 'cover', 'series')"
           )

    create constraint(:record_candidates, :record_candidates_review_status_check,
             check: "review_status IN ('needs_review', 'accepted', 'rejected', 'quarantined')"
           )

    create table(:ingestion_events, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true

      add :provider_run_id,
          references(:provider_runs,
            column: :id,
            name: "ingestion_events_provider_run_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :delete_all
          ),
          null: false

      add :provider_source_id,
          references(:provider_sources,
            column: :id,
            name: "ingestion_events_provider_source_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :delete_all
          ),
          null: false

      add :source_snapshot_id,
          references(:source_snapshots,
            column: :id,
            name: "ingestion_events_source_snapshot_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :nilify_all
          )

      add :event_kind, :text, null: false
      add :status, :text, null: false
      add :message, :text
      add :payload, :map, null: false, default: %{}
      add :occurred_at, :utc_datetime, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:ingestion_events, [:provider_run_id, :event_kind, :occurred_at, :id],
             name: "ingestion_events_unique_ingestion_event_index"
           )

    create index(:ingestion_events, [:provider_run_id],
             name: "ingestion_events_provider_run_id_index"
           )

    create index(:ingestion_events, [:provider_source_id],
             name: "ingestion_events_provider_source_id_index"
           )

    create index(:ingestion_events, [:source_snapshot_id],
             name: "ingestion_events_source_snapshot_id_index"
           )

    create index(:ingestion_events, [:event_kind], name: "ingestion_events_event_kind_index")
    create index(:ingestion_events, [:status], name: "ingestion_events_status_index")
    create index(:ingestion_events, [:occurred_at], name: "ingestion_events_occurred_at_index")

    create constraint(:ingestion_events, :ingestion_events_status_check,
             check: "status IN ('queued', 'running', 'succeeded', 'failed', 'warning')"
           )
  end
end
