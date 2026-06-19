defmodule Hiraeth.Sources.SourceRecord do
  use Ash.Resource,
    domain: Hiraeth.Sources,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "source_records"
    repo Hiraeth.Repo

    custom_indexes do
      index :source_uri, name: "source_records_public_catalog_source_uri_index"
      index [:provider, :source_type], name: "source_records_public_catalog_provider_type_index"
      index :edition_id, name: "source_records_public_catalog_edition_id_index"
      index :source_identity, name: "source_records_public_catalog_source_identity_index"
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :provider, :string do
      allow_nil? false
      public? true
    end

    attribute :source_type, :string do
      allow_nil? false
      public? true
    end

    attribute :source_uri, :string do
      public? true
    end

    attribute :file_checksum, :string do
      public? true
    end

    attribute :source_identity, :string do
      public? true
    end

    attribute :license_note, :string do
      allow_nil? false
      public? true
    end

    attribute :raw_payload, :map do
      allow_nil? false
      public? false
    end

    attribute :imported_at, :utc_datetime do
      allow_nil? false
      public? true
    end
  end

  relationships do
    belongs_to :import_run, Hiraeth.Imports.ImportRun do
      public? true
      allow_nil? true
    end

    belongs_to :edition, Hiraeth.Catalog.Edition do
      public? true
      allow_nil? true
    end

    has_many :curation_overrides, Hiraeth.Sources.CurationOverride
    has_many :ledger_entries, Hiraeth.Sources.SourceLedgerEntry
  end

  identities do
    identity :unique_source_record, [:provider, :source_type, :source_uri, :file_checksum]
  end

  actions do
    defaults [:read]

    create :create do
      primary? true

      accept [
        :provider,
        :source_type,
        :source_uri,
        :file_checksum,
        :license_note,
        :source_identity,
        :raw_payload,
        :imported_at,
        :import_run_id,
        :edition_id
      ]
    end
  end

  policies do
    policy action_type(:read) do
      description "Source provenance is readable for audit and catalog review."
      authorize_if always()
    end

    policy action_type(:create) do
      description "Only trusted catalog write actors can ingest source records."
      authorize_if actor_attribute_equals(:catalog_write?, true)
    end

    policy action_type(:update) do
      description "Raw source records are immutable after ingestion."
      forbid_if always()
    end
  end
end
