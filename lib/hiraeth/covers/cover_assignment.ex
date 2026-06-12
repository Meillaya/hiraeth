defmodule Hiraeth.Covers.CoverAssignment do
  use Ash.Resource,
    domain: Hiraeth.Covers,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "cover_assignments"
    repo Hiraeth.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :position, :integer do
      public? true
    end

    attribute :visible?, :boolean do
      allow_nil? false
      default true
      public? true
    end
  end

  relationships do
    belongs_to :cover_asset, Hiraeth.Covers.CoverAsset, allow_nil?: false
    belongs_to :edition, Hiraeth.Catalog.Edition, allow_nil?: false
  end

  identities do
    identity :unique_edition_cover, [:edition_id, :cover_asset_id]
  end

  actions do
    defaults [:read, :destroy]

    read :public do
      filter expr(visible? == true)
      prepare build(default_sort: [position: :asc, id: :asc])
    end

    read :public_for_edition do
      argument :edition_id, :uuid, allow_nil?: false
      filter expr(visible? == true and edition_id == ^arg(:edition_id))
      prepare build(default_sort: [position: :asc, id: :asc])
    end

    create :create do
      primary? true
      accept [:position, :visible?, :cover_asset_id, :edition_id]
    end

    update :update do
      accept [:position, :visible?]
    end
  end

  policies do
    policy action_type(:read) do
      description "Cover assignments are publicly readable for cover resolution."
      authorize_if always()
    end

    policy action_type([:create, :update, :destroy]) do
      description "Only admin actors can assign covers to editions."
      authorize_if actor_attribute_equals(:admin?, true)
    end
  end
end
