defmodule Hiraeth.Catalog.Work do
  use Ash.Resource,
    domain: Hiraeth.Catalog,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "works"
    repo Hiraeth.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :title, :string do
      allow_nil? false
      public? true
    end

    attribute :subtitle, :string do
      public? true
    end

    attribute :original_title, :string do
      public? true
    end

    attribute :original_language_code, :string do
      public? true
    end

    attribute :subjects, {:array, :string} do
      allow_nil? false
      default []
      public? true
    end

    attribute :slug, :string do
      allow_nil? false
      public? true
    end

    attribute :publication_state, :string do
      allow_nil? false
      default "draft"
      public? true
    end

    attribute :description, :string do
      public? true
    end

    attribute :storefront_url, :string do
      public? true
    end

    attribute :editorial_praise, {:array, :map} do
      allow_nil? false
      default []
      public? true
    end
  end

  relationships do
    has_many :editions, Hiraeth.Catalog.Edition
    has_many :contributions, Hiraeth.Catalog.Contribution
    has_many :series_memberships, Hiraeth.Catalog.SeriesMembership
  end

  identities do
    identity :unique_slug, [:slug]
  end

  validations do
    validate match(:original_language_code, ~r/^[a-z]{3}$/),
      message: "must be a lowercase ISO 639-3 language code"
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true

      accept [
        :title,
        :subtitle,
        :original_title,
        :original_language_code,
        :subjects,
        :slug,
        :publication_state,
        :description,
        :storefront_url,
        :editorial_praise
      ]
    end

    update :update do
      require_atomic? false

      accept [
        :title,
        :subtitle,
        :original_title,
        :original_language_code,
        :subjects,
        :slug,
        :publication_state,
        :description,
        :storefront_url,
        :editorial_praise
      ]
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
