defmodule Hiraeth.Ingestion.ProviderRun do
  use Ash.Resource,
    domain: Hiraeth.Ingestion,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "provider_runs"
    repo Hiraeth.Repo

    custom_indexes do
      index :provider_source_id, name: "provider_runs_provider_source_id_index"
      index :status, name: "provider_runs_status_index"
      index [:provider_source_id, :status], name: "provider_runs_source_status_index"
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :status, :string, allow_nil?: false, default: "queued", public?: true
    attribute :requested_by, :string, public?: true
    attribute :run_key, :string, allow_nil?: false, public?: true

    attribute :provenance, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :started_at, :utc_datetime, public?: true
    attribute :finished_at, :utc_datetime, public?: true

    for attribute <- [
          :source_count,
          :snapshot_count,
          :candidate_count,
          :accepted_count,
          :rejected_count,
          :error_count
        ] do
      attribute attribute, :integer do
        allow_nil? false
        default 0
        constraints min: 0
        public? true
      end
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :provider_source, Hiraeth.Ingestion.ProviderSource do
      allow_nil? false
      public? true
    end

    has_many :source_snapshots, Hiraeth.Ingestion.SourceSnapshot
    has_many :record_candidates, Hiraeth.Ingestion.RecordCandidate
    has_many :ingestion_events, Hiraeth.Ingestion.IngestionEvent
  end

  identities do
    identity :unique_provider_run_key, [:provider_source_id, :run_key]
  end

  validations do
    validate one_of(:status, ["queued", "running", "succeeded", "failed", "cancelled"])
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true

      accept [
        :provider_source_id,
        :status,
        :requested_by,
        :run_key,
        :provenance,
        :started_at,
        :finished_at,
        :source_count,
        :snapshot_count,
        :candidate_count,
        :accepted_count,
        :rejected_count,
        :error_count
      ]
    end

    update :mark_running do
      accept [:started_at]
      change set_attribute(:status, "running")
    end

    update :mark_succeeded do
      accept [
        :finished_at,
        :source_count,
        :snapshot_count,
        :candidate_count,
        :accepted_count,
        :rejected_count,
        :error_count
      ]

      change set_attribute(:status, "succeeded")
    end

    update :mark_failed do
      accept [
        :finished_at,
        :source_count,
        :snapshot_count,
        :candidate_count,
        :accepted_count,
        :rejected_count,
        :error_count
      ]

      change set_attribute(:status, "failed")
    end

    update :cancel do
      accept [:finished_at]
      change set_attribute(:status, "cancelled")
    end

    update :record_progress do
      require_atomic? false

      accept [
        :status,
        :provenance,
        :started_at,
        :finished_at,
        :source_count,
        :snapshot_count,
        :candidate_count,
        :accepted_count,
        :rejected_count,
        :error_count
      ]
    end
  end

  policies do
    policy action_type(:read) do
      description "Provider runs are readable for ingestion monitoring."
      authorize_if always()
    end

    policy action_type([:create, :update, :destroy]) do
      description "Only trusted catalog write actors can manage provider runs."
      authorize_if actor_attribute_equals(:catalog_write?, true)
    end
  end
end
