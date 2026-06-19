defmodule Hiraeth.Catalog.Identifier do
  use Ash.Resource,
    domain: Hiraeth.Catalog,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "identifiers"
    repo Hiraeth.Repo

    custom_indexes do
      index :edition_id, name: "identifiers_public_catalog_edition_id_index"
      index :value, name: "identifiers_public_catalog_value_index"
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :identifier_type, :string do
      allow_nil? false
      public? true
    end

    attribute :value, :string do
      allow_nil? false
      public? true
    end
  end

  relationships do
    belongs_to :edition, Hiraeth.Catalog.Edition, allow_nil?: false
  end

  identities do
    identity :unique_identifier, [:identifier_type, :value]
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:identifier_type, :value, :edition_id]
    end

    update :update do
      accept [:identifier_type, :value, :edition_id]
    end
  end

  policies do
    policy action_type(:read) do
      description "Catalog records are publicly readable for browsing."
      authorize_if always()
    end

    policy action_type([:create, :update, :destroy]) do
      description "Only trusted catalog write actors can write catalog records."
      authorize_if actor_attribute_equals(:catalog_write?, true)
    end
  end
end
