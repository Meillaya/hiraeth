defmodule Hiraeth.Catalog.PublicProjection.Book do
  @moduledoc "Work-centric public catalog book projection."

  @behaviour Access

  @enforce_keys [:id, :work_id, :title, :slug, :publisher, :publisher_slug, :formats]
  defstruct [
    :id,
    :work_id,
    :title,
    :subtitle,
    :slug,
    :publisher,
    :publisher_slug,
    :author,
    :cover,
    :source,
    :original_title,
    :original_language_code,
    :description,
    :storefront_url,
    :isbn,
    :published_on,
    :year,
    authors: [],
    translators: [],
    contributors_by_role: %{},
    contributor_names: [],
    series_titles: [],
    series_slug: nil,
    subjects: [],
    editorial_praise: [],
    praise: [],
    review_links: [],
    missing_fields: %{},
    formats: [],
    identifiers: [],
    sources: []
  ]

  defdelegate fetch(projection, key), to: Hiraeth.Catalog.PublicProjection.Access

  defdelegate get_and_update(projection, key, function),
    to: Hiraeth.Catalog.PublicProjection.Access

  defdelegate pop(projection, key), to: Hiraeth.Catalog.PublicProjection.Access
end
