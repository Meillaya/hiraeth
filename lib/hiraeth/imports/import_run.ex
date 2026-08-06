defmodule Hiraeth.Imports.ImportRun do
  @moduledoc "Ash resource: an import run row carrying apply/tombstone provenance lineage."

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

  identities do
    identity :unique_provider_status, [:provider, :status, :id]
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:provider, :status, :row_limit]
    end

    update :update do
      accept [:provider, :status, :row_limit]
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
