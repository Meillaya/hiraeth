defmodule Hiraeth.Audit.AuditEvent do
  use Ash.Resource,
    domain: Hiraeth.Audit,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "audit_events"
    repo Hiraeth.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :event_type, :string do
      allow_nil? false
      public? true
    end

    attribute :entity_type, :string do
      public? true
    end

    attribute :entity_id, :uuid do
      public? true
    end

    attribute :metadata, :map do
      public? false
    end

    attribute :occurred_at, :utc_datetime do
      public? true
    end

    attribute :actor_id, :uuid do
      public? false
    end
  end

  identities do
    identity :unique_audit_event, [:event_type, :entity_type, :entity_id, :occurred_at]
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:event_type, :entity_type, :entity_id, :metadata, :occurred_at, :actor_id]
    end
  end

  policies do
    policy action_type(:read) do
      description "Public read placeholder for catalog browsing and catalog review screens."
      authorize_if always()
    end

    policy action_type(:create) do
      description "Only trusted catalog write actors can append audit events. Existing audit events are immutable."
      authorize_if actor_attribute_equals(:catalog_write?, true)
    end
  end
end
