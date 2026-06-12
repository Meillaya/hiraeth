defmodule Hiraeth.Catalog.Contributor do
  use Ash.Resource,
    domain: Hiraeth.Catalog,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "contributors"
    repo Hiraeth.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :display_name, :string do
      allow_nil? false
      public? true
    end

    attribute :sort_name, :string do
      public? true
    end

    attribute :slug, :string do
      allow_nil? false
      public? true
    end
  end

  relationships do
    has_many :contributions, Hiraeth.Catalog.Contribution
  end

  identities do
    identity :unique_slug, [:slug]
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:display_name, :sort_name, :slug]
    end

    update :update do
      accept [:display_name, :sort_name, :slug]
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
