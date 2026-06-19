defmodule Hiraeth.Catalog.Imprint do
  use Ash.Resource,
    domain: Hiraeth.Catalog,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "imprints"
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
  end

  relationships do
    belongs_to :publisher, Hiraeth.Catalog.Publisher, allow_nil?: false
    has_many :editions, Hiraeth.Catalog.Edition
  end

  identities do
    identity :unique_publisher_slug, [:publisher_id, :slug]
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:name, :slug, :publisher_id]
    end

    update :update do
      accept [:name, :slug, :publisher_id]
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
