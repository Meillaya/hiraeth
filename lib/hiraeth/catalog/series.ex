defmodule Hiraeth.Catalog.Series do
  use Ash.Resource,
    domain: Hiraeth.Catalog,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "series"
    repo Hiraeth.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :title, :string do
      allow_nil? false
      public? true
    end

    attribute :slug, :string do
      allow_nil? false
      public? true
    end
  end

  relationships do
    belongs_to :publisher, Hiraeth.Catalog.Publisher, allow_nil?: true
    has_many :series_memberships, Hiraeth.Catalog.SeriesMembership
  end

  identities do
    identity :unique_slug, [:slug]
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:title, :slug, :publisher_id]
    end

    update :update do
      accept [:title, :slug, :publisher_id]
    end
  end

  policies do
    policy action_type(:read) do
      description "Catalog records are publicly readable for browsing."
      authorize_if always()
    end

    policy action_type([:create, :update, :destroy]) do
      description "Only authenticated admin actors can write catalog records."
      authorize_if actor_attribute_equals(:admin?, true)
    end
  end
end
