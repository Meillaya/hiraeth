defmodule Hiraeth.Imports.ImportMapping do
  use Ash.Resource,
    domain: Hiraeth.Imports,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "import_mappings"
    repo Hiraeth.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :source_column, :string do
      allow_nil? false
      public? true
    end

    attribute :target_field, :string do
      allow_nil? false
      public? true
    end
  end

  relationships do
    belongs_to :import_run, Hiraeth.Imports.ImportRun, allow_nil?: false
  end

  identities do
    identity :unique_import_mapping, [:import_run_id, :source_column, :target_field]
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:source_column, :target_field, :import_run_id]
    end

    update :update do
      accept [:source_column, :target_field, :import_run_id]
    end

    destroy :destroy_for_remap do
      primary? false
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
