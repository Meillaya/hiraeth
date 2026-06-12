defmodule Hiraeth.Catalog.Contribution do
  use Ash.Resource,
    domain: Hiraeth.Catalog,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "contributions"
    repo Hiraeth.Repo

    custom_indexes do
      index :work_id, name: "contributions_public_catalog_work_id_index"
      index :edition_id, name: "contributions_public_catalog_edition_id_index"
      index :contributor_id, name: "contributions_public_catalog_contributor_id_index"
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :role, :string do
      allow_nil? false
      public? true
    end

    attribute :position, :integer do
      public? true
    end
  end

  relationships do
    belongs_to :contributor, Hiraeth.Catalog.Contributor, allow_nil?: false
    belongs_to :work, Hiraeth.Catalog.Work, allow_nil?: true
    belongs_to :edition, Hiraeth.Catalog.Edition, allow_nil?: true
  end

  identities do
    identity :unique_contribution_slot, [:contributor_id, :role, :work_id, :edition_id]
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:role, :position, :contributor_id, :work_id, :edition_id]
    end

    update :update do
      accept [:role, :position, :contributor_id, :work_id, :edition_id]
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
