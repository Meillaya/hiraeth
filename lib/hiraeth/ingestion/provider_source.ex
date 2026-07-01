defmodule Hiraeth.Ingestion.ProviderSource do
  use Ash.Resource,
    domain: Hiraeth.Ingestion,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "provider_sources"
    repo Hiraeth.Repo

    custom_indexes do
      index :source_kind, name: "provider_sources_source_kind_index"
      index :ingestion_mode, name: "provider_sources_ingestion_mode_index"
      index :enabled?, name: "provider_sources_enabled_index"
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :stable_source_key, :string, allow_nil?: false, public?: true
    attribute :provider_name, :string, allow_nil?: false, public?: true
    attribute :source_kind, :string, allow_nil?: false, public?: true
    attribute :ingestion_mode, :string, allow_nil?: false, public?: true
    attribute :base_uri, :string, public?: true
    attribute :manifest_uri, :string, public?: true

    attribute :allowed_hosts, {:array, :string} do
      allow_nil? false
      default []
      public? true
    end

    attribute :rate_limit_per_minute, :integer do
      constraints min: 1
      public? true
    end

    attribute :max_bytes, :integer do
      constraints min: 1
      public? true
    end

    attribute :checksum_algorithm, :string, public?: true
    attribute :required_checksum, :string, public?: true
    attribute :license_note, :string, public?: true
    attribute :enabled?, :boolean, allow_nil?: false, default: false, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :provider_runs, Hiraeth.Ingestion.ProviderRun
    has_many :source_snapshots, Hiraeth.Ingestion.SourceSnapshot
    has_many :ingestion_events, Hiraeth.Ingestion.IngestionEvent
  end

  identities do
    identity :unique_stable_source_key, [:stable_source_key]
  end

  validations do
    validate one_of(:source_kind, ["publisher", "bookstore", "distributor", "manual"])
    validate one_of(:ingestion_mode, ["manifest", "scrape", "api", "manual"])
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true

      accept [
        :stable_source_key,
        :provider_name,
        :source_kind,
        :ingestion_mode,
        :base_uri,
        :manifest_uri,
        :allowed_hosts,
        :rate_limit_per_minute,
        :max_bytes,
        :checksum_algorithm,
        :required_checksum,
        :license_note,
        :enabled?
      ]
    end

    update :update do
      require_atomic? false

      accept [
        :provider_name,
        :source_kind,
        :ingestion_mode,
        :base_uri,
        :manifest_uri,
        :allowed_hosts,
        :rate_limit_per_minute,
        :max_bytes,
        :checksum_algorithm,
        :required_checksum,
        :license_note,
        :enabled?
      ]
    end
  end

  policies do
    policy action_type(:read) do
      description "Provider source configuration is readable for ingestion review."
      authorize_if always()
    end

    policy action_type([:create, :update, :destroy]) do
      description "Only trusted catalog write actors can manage provider sources."
      authorize_if actor_attribute_equals(:catalog_write?, true)
    end
  end
end
