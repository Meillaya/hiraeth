defmodule Hiraeth.Catalog.Publisher do
  use Ash.Resource,
    domain: Hiraeth.Catalog,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "publishers"
    repo Hiraeth.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :slug, :string do
      allow_nil? false
      public? true
    end

    attribute :description, :string do
      public? true
    end
  end

  relationships do
    has_many :imprints, Hiraeth.Catalog.Imprint
    has_many :series, Hiraeth.Catalog.Series
    has_many :editions, Hiraeth.Catalog.Edition
  end

  identities do
    identity :unique_slug, [:slug]
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:name, :slug, :description]
    end

    update :update do
      accept [:name, :slug, :description]
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
