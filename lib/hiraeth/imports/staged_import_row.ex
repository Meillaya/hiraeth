defmodule Hiraeth.Imports.StagedImportRow do
  use Ash.Resource,
    domain: Hiraeth.Imports,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "staged_import_rows"
    repo Hiraeth.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :row_number, :integer do
      allow_nil? false
      public? true
    end

    attribute :raw_payload, :map do
      public? false
    end

    attribute :status, :string do
      allow_nil? false
      default "pending"
      public? true
    end
  end

  relationships do
    belongs_to :import_run, Hiraeth.Imports.ImportRun, allow_nil?: false
    has_many :review_items, Hiraeth.Imports.ReviewItem
  end

  identities do
    identity :unique_import_row, [:import_run_id, :row_number]
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:row_number, :raw_payload, :status, :import_run_id]
    end

    update :update do
      accept [:row_number, :raw_payload, :status, :import_run_id]
    end

    update :reject_row do
      require_atomic? false
      argument :reason, :string, allow_nil?: false, public?: true
      change set_attribute(:status, "rejected")
    end
  end

  policies do
    policy action_type(:read) do
      description "Public read placeholder for catalog browsing and admin review screens."
      authorize_if always()
    end

    policy action_type([:create, :update, :destroy]) do
      description "Admin-only write placeholder; concrete policies are tightened in feature tasks."
      authorize_if actor_attribute_equals(:admin?, true)
    end
  end
end
