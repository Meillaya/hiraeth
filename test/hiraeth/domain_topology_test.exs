defmodule Hiraeth.DomainTopologyTest do
  use ExUnit.Case, async: true

  @domains [
    Hiraeth.Catalog,
    Hiraeth.Sources,
    Hiraeth.Covers,
    Hiraeth.Imports,
    Hiraeth.Search,
    Hiraeth.Audit
  ]

  @resources %{
    Hiraeth.Catalog => [
      Hiraeth.Catalog.Publisher,
      Hiraeth.Catalog.Imprint,
      Hiraeth.Catalog.Work,
      Hiraeth.Catalog.Edition,
      Hiraeth.Catalog.Contributor,
      Hiraeth.Catalog.Contribution,
      Hiraeth.Catalog.Identifier,
      Hiraeth.Catalog.Series,
      Hiraeth.Catalog.SeriesMembership
    ],
    Hiraeth.Sources => [
      Hiraeth.Sources.SourceRecord,
      Hiraeth.Sources.CurationOverride,
      Hiraeth.Sources.SourceLedgerEntry
    ],
    Hiraeth.Covers => [Hiraeth.Covers.CoverAsset, Hiraeth.Covers.CoverAssignment],
    Hiraeth.Imports => [
      Hiraeth.Imports.ImportRun,
      Hiraeth.Imports.ImportMapping,
      Hiraeth.Imports.StagedImportRow,
      Hiraeth.Imports.ReviewItem
    ],
    Hiraeth.Search => [Hiraeth.Search.Result],
    Hiraeth.Audit => [Hiraeth.Audit.AuditEvent]
  }

  test "Ash domains are configured and compile" do
    configured_domains = Application.fetch_env!(:hiraeth, :ash_domains)

    assert MapSet.new(configured_domains) == MapSet.new(@domains)

    for domain <- @domains do
      assert Code.ensure_loaded?(domain)
      assert function_exported?(domain, :spark_is, 0)
      assert domain.spark_is() == Ash.Domain
    end
  end

  test "all planned resources are registered in their domains with UUID primary keys" do
    for {domain, resources} <- @resources do
      registered = Ash.Domain.Info.resources(domain)
      assert MapSet.new(registered) == MapSet.new(resources)

      for resource <- resources do
        assert Code.ensure_loaded?(resource)
        assert Ash.Resource.Info.domain(resource) == domain

        assert Ash.Resource.Info.primary_key(resource) == [:id]

        id = Enum.find(Ash.Resource.Info.attributes(resource), &(&1.name == :id))
        assert id.type == Ash.Type.UUID
        assert id.public? == true

        public_attributes =
          resource
          |> Ash.Resource.Info.attributes()
          |> Enum.reject(& &1.primary_key?)
          |> Enum.filter(& &1.public?)

        assert public_attributes != []
        assert Ash.Resource.Info.identities(resource) != []
      end
    end
  end

  test "catalog topology keeps works and editions separate without a canonical Book resource" do
    refute Code.ensure_loaded?(Hiraeth.Catalog.Book)
    refute Code.ensure_loaded?(Hiraeth.Book)

    catalog_resources = Ash.Domain.Info.resources(Hiraeth.Catalog)
    assert Hiraeth.Catalog.Work in catalog_resources
    assert Hiraeth.Catalog.Edition in catalog_resources

    work_relationships = relationship_names(Hiraeth.Catalog.Work)
    edition_relationships = relationship_names(Hiraeth.Catalog.Edition)
    identifier_relationships = relationship_names(Hiraeth.Catalog.Identifier)

    assert :editions in work_relationships
    assert :work in edition_relationships
    assert :identifiers in edition_relationships
    assert :edition in identifier_relationships
  end

  test "authorization placeholders are present on skeleton resources" do
    for resources <- Map.values(@resources), resource <- resources do
      assert Ash.Policy.Authorizer in Ash.Resource.Info.authorizers(resource)
    end
  end

  defp relationship_names(resource) do
    resource
    |> Ash.Resource.Info.relationships()
    |> Enum.map(& &1.name)
  end
end
