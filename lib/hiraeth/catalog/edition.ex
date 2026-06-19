defmodule Hiraeth.Catalog.Edition do
  use Ash.Resource,
    domain: Hiraeth.Catalog,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "editions"
    repo Hiraeth.Repo

    custom_indexes do
      index :work_id, name: "editions_public_catalog_work_id_index"
      index :publisher_id, name: "editions_public_catalog_publisher_id_index"
      index :imprint_id, name: "editions_public_catalog_imprint_id_index"
    end
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

    attribute :slug, :string do
      allow_nil? false
      public? true
    end

    attribute :format, :string do
      public? true
    end

    attribute :language_code, :string do
      public? true
    end

    attribute :page_count, :integer do
      constraints min: 1
      public? true
    end

    attribute :height_mm, :integer do
      constraints min: 1
      public? true
    end

    attribute :width_mm, :integer do
      constraints min: 1
      public? true
    end

    attribute :depth_mm, :integer do
      constraints min: 1
      public? true
    end

    attribute :published_on, :date do
      public? true
    end
  end

  relationships do
    belongs_to :work, Hiraeth.Catalog.Work, allow_nil?: false
    belongs_to :publisher, Hiraeth.Catalog.Publisher, allow_nil?: false
    belongs_to :imprint, Hiraeth.Catalog.Imprint, allow_nil?: true
    has_many :identifiers, Hiraeth.Catalog.Identifier
    has_many :source_records, Hiraeth.Sources.SourceRecord
    has_many :contributions, Hiraeth.Catalog.Contribution
    has_many :cover_assignments, Hiraeth.Covers.CoverAssignment
  end

  identities do
    identity :unique_slug, [:slug]
  end

  validations do
    validate match(:language_code, ~r/^[a-z]{3}$/),
      message: "must be a lowercase ISO 639-3 language code"
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true

      accept [
        :title,
        :subtitle,
        :slug,
        :format,
        :language_code,
        :page_count,
        :height_mm,
        :width_mm,
        :depth_mm,
        :published_on,
        :work_id,
        :publisher_id,
        :imprint_id
      ]
    end

    create :create_with_catalog_edges do
      accept [
        :title,
        :subtitle,
        :slug,
        :format,
        :language_code,
        :page_count,
        :height_mm,
        :width_mm,
        :depth_mm,
        :published_on,
        :work_id,
        :publisher_id,
        :imprint_id
      ]

      argument :contributor, :map do
        allow_nil? false
        public? true
      end

      argument :identifier, :map do
        allow_nil? false
        public? true
      end

      argument :cover, :map do
        allow_nil? true
        default %{}
        public? true
      end

      change after_action(fn changeset, edition, context ->
               Hiraeth.Catalog.Edition.NestedCatalogEdges.apply!(
                 changeset,
                 edition,
                 context.actor
               )
             end)
    end

    update :update do
      require_atomic? false

      accept [
        :title,
        :subtitle,
        :slug,
        :format,
        :language_code,
        :page_count,
        :height_mm,
        :width_mm,
        :depth_mm,
        :published_on,
        :work_id,
        :publisher_id,
        :imprint_id
      ]
    end
  end

  policies do
    policy action_type(:read) do
      description "Catalog records are publicly readable for browsing."
      authorize_if always()
    end

    policy action_type([:create, :update, :destroy]) do
      description "Only trusted catalog write actors can write catalog records."
      authorize_if actor_attribute_equals(:catalog_write?, true)
    end
  end
end
