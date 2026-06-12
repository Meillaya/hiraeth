defmodule Hiraeth.Catalog.SeriesMembership do
  use Ash.Resource,
    domain: Hiraeth.Catalog,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "series_memberships"
    repo Hiraeth.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :position, :integer do
      public? true
    end

    attribute :label, :string do
      public? true
    end
  end

  relationships do
    belongs_to :series, Hiraeth.Catalog.Series, allow_nil?: false
    belongs_to :work, Hiraeth.Catalog.Work, allow_nil?: false
  end

  identities do
    identity :unique_series_work, [:series_id, :work_id]
  end

  actions do
    defaults [:read, :destroy]

    read :by_series do
      argument :series_id, :uuid, allow_nil?: false

      filter expr(series_id == ^arg(:series_id))
      prepare build(default_sort: [position: :asc])
    end

    create :create do
      primary? true
      accept [:position, :label, :series_id, :work_id]
    end

    update :update do
      accept [:position, :label, :series_id, :work_id]
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
