defmodule Hiraeth.Imports.ReviewItem do
  use Ash.Resource,
    domain: Hiraeth.Imports,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "review_items"
    repo Hiraeth.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :entity_type, :string do
      allow_nil? false
      public? true
    end

    attribute :decision, :string do
      allow_nil? false
      default "pending"
      public? true
    end

    attribute :message, :string do
      public? true
    end
  end

  relationships do
    belongs_to :import_run, Hiraeth.Imports.ImportRun, allow_nil?: false
    belongs_to :staged_import_row, Hiraeth.Imports.StagedImportRow, allow_nil?: true
  end

  identities do
    identity :unique_review_item, [:import_run_id, :entity_type, :id]
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:entity_type, :decision, :message, :import_run_id, :staged_import_row_id]
    end

    update :update do
      accept [:entity_type, :decision, :message, :import_run_id, :staged_import_row_id]
    end

    update :approve_review_item do
      accept []
      change set_attribute(:decision, "approved")
    end

    update :reject_review_item do
      accept []
      change set_attribute(:decision, "rejected")
    end
  end

  policies do
    policy action_type(:read) do
      description "Public read placeholder for catalog browsing and catalog review screens."
      authorize_if always()
    end

    policy action_type([:create, :update, :destroy]) do
      description "Trusted catalog write placeholder; concrete policies are tightened in feature tasks."
      authorize_if actor_attribute_equals(:catalog_write?, true)
    end
  end
end
