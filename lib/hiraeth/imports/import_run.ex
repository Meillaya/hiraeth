defmodule Hiraeth.Imports.ImportRun do
  use Ash.Resource,
    domain: Hiraeth.Imports,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "import_runs"
    repo Hiraeth.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :provider, :string do
      allow_nil? false
      public? true
    end

    attribute :status, :string do
      allow_nil? false
      default "draft"
      public? true
    end

    attribute :row_limit, :integer do
      allow_nil? false
      default 250
      public? true
    end
  end

  relationships do
    has_many :mappings, Hiraeth.Imports.ImportMapping
    has_many :staged_rows, Hiraeth.Imports.StagedImportRow
    has_many :review_items, Hiraeth.Imports.ReviewItem
  end

  identities do
    identity :unique_provider_status, [:provider, :status, :id]
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:provider, :status, :row_limit]
    end

    create :upload_csv do
      accept [:provider]

      argument :file_name, :string do
        allow_nil? false
        public? true
      end

      argument :csv_content, :string do
        allow_nil? false
        constraints allow_empty?: true, trim?: false
        public? true
      end

      manual Hiraeth.Imports.ImportRun.Actions.CsvWorkflow
    end

    update :update do
      accept [:provider, :status, :row_limit]
    end

    update :map_columns do
      require_atomic? false
      argument :mappings, :map, allow_nil?: false, public?: true
      change set_attribute(:status, "mapped")
      change after_action(&Hiraeth.Imports.ImportRun.Actions.CsvWorkflow.map_columns/3)
    end

    update :dry_run do
      accept []
      change set_attribute(:status, "dry_run")
    end

    update :validate_rows do
      require_atomic? false
      accept []
      change set_attribute(:status, "validated")
      change after_action(&Hiraeth.Imports.ImportRun.Actions.CsvWorkflow.validate_rows/3)
    end

    update :apply_accepted_rows do
      require_atomic? false
      accept []
      change set_attribute(:status, "applied")
      change after_action(&Hiraeth.Imports.ImportRun.Actions.CsvWorkflow.apply_rows/3)
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
