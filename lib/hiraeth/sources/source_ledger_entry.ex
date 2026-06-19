defmodule Hiraeth.Sources.SourceLedgerEntry do
  use Ash.Resource,
    domain: Hiraeth.Sources,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "source_ledger_entries"
    repo Hiraeth.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :event_type, :string do
      allow_nil? false
      public? true
    end

    attribute :message, :string do
      public? true
    end

    attribute :occurred_at, :utc_datetime do
      allow_nil? false
      public? true
    end
  end

  relationships do
    belongs_to :source_record, Hiraeth.Sources.SourceRecord, allow_nil?: false
  end

  identities do
    identity :unique_source_event, [:source_record_id, :event_type, :occurred_at]
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:event_type, :message, :occurred_at, :source_record_id]
    end

    update :update do
      accept [:message]
    end
  end

  policies do
    policy action_type(:read) do
      description "Source ledger entries are readable for audit and catalog review."
      authorize_if always()
    end

    policy action_type([:create, :update, :destroy]) do
      description "Only trusted catalog write actors can write source ledger entries."
      authorize_if actor_attribute_equals(:catalog_write?, true)
    end
  end
end
