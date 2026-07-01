defmodule Hiraeth.Ingestion.IngestionEvent do
  use Ash.Resource,
    domain: Hiraeth.Ingestion,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "ingestion_events"
    repo Hiraeth.Repo

    custom_indexes do
      index :provider_run_id, name: "ingestion_events_provider_run_id_index"
      index :provider_source_id, name: "ingestion_events_provider_source_id_index"
      index :source_snapshot_id, name: "ingestion_events_source_snapshot_id_index"
      index :event_kind, name: "ingestion_events_event_kind_index"
      index :status, name: "ingestion_events_status_index"
      index :occurred_at, name: "ingestion_events_occurred_at_index"
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :event_kind, :string, allow_nil?: false, public?: true
    attribute :status, :string, allow_nil?: false, public?: true
    attribute :message, :string, public?: true

    attribute :payload, :map do
      allow_nil? false
      default %{}
      public? false
    end

    attribute :occurred_at, :utc_datetime, allow_nil?: false, public?: true

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :provider_run, Hiraeth.Ingestion.ProviderRun do
      allow_nil? false
      public? true
    end

    belongs_to :provider_source, Hiraeth.Ingestion.ProviderSource do
      allow_nil? false
      public? true
    end

    belongs_to :source_snapshot, Hiraeth.Ingestion.SourceSnapshot do
      allow_nil? true
      public? true
    end
  end

  identities do
    identity :unique_ingestion_event, [:provider_run_id, :event_kind, :occurred_at, :id]
  end

  validations do
    validate one_of(:status, ["queued", "running", "succeeded", "failed", "warning"])
  end

  actions do
    defaults [:read]

    create :create do
      primary? true

      accept [
        :provider_run_id,
        :provider_source_id,
        :source_snapshot_id,
        :event_kind,
        :status,
        :message,
        :payload,
        :occurred_at
      ]
    end
  end

  policies do
    policy action_type(:read) do
      description "Ingestion events are readable for run review."
      authorize_if always()
    end

    policy action_type(:create) do
      description "Only trusted catalog write actors can append ingestion events."
      authorize_if actor_attribute_equals(:catalog_write?, true)
    end

    policy action_type([:update, :destroy]) do
      description "Ingestion events are append-only audit records."
      forbid_if always()
    end
  end
end
