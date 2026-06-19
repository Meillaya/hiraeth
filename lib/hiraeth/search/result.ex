defmodule Hiraeth.Search.Result do
  @moduledoc """
  Internal Ash search projection retained for internal catalog search tests.

  Public browser discovery must use `HiraethWeb.PublicCatalog`, which is backed
  by bounded Postgres queries and facets. This resource intentionally does not
  declare itself as a public catalog path because its manual read hydrates the
  full edition set before filtering.
  """

  use Ash.Resource,
    domain: Hiraeth.Search,
    authorizers: [Ash.Policy.Authorizer],
    primary_read_warning?: false

  def public_catalog_path?, do: false

  attributes do
    uuid_primary_key :id

    attribute :edition_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :work_id, :uuid do
      allow_nil? false
      public? true
    end

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

    attribute :publisher_name, :string do
      allow_nil? false
      public? true
    end

    attribute :imprint_name, :string do
      public? true
    end

    attribute :contributor_names, {:array, :string} do
      allow_nil? false
      default []
      public? true
    end

    attribute :series_titles, {:array, :string} do
      allow_nil? false
      default []
      public? true
    end

    attribute :identifiers, {:array, :string} do
      allow_nil? false
      default []
      public? true
    end

    attribute :published_on, :date do
      public? true
    end
  end

  identities do
    identity :unique_search_result, [:edition_id]
  end

  actions do
    read :search do
      primary? true

      argument :query, :string do
        allow_nil? false
        constraints allow_empty?: true, trim?: false
      end

      manual Hiraeth.Search.Result.Actions.Search

      pagination do
        required? false
        offset? true
        countable true
        default_limit 20
        max_page_size 100
      end
    end
  end

  policies do
    policy action_type(:read) do
      description "Search results are internal catalog projections; browser catalog pages use PublicCatalog."
      authorize_if always()
    end
  end
end
