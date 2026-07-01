defmodule Hiraeth.Catalog.PublicProjection do
  @moduledoc """
  Stable typed projections for public catalog reads.

  These structs describe the public browser catalog boundary. They are not a
  JSON API, but they are the shape future public representations must version
  from instead of serializing Ash resources or SQL rows directly.
  """

  alias __MODULE__.{Book, Contributor, Cover, Format, Source}

  @book_fields Book.__struct__() |> Map.from_struct() |> Map.keys()
  @format_fields Format.__struct__() |> Map.from_struct() |> Map.keys()
  @contributor_fields Contributor.__struct__() |> Map.from_struct() |> Map.keys()
  @cover_fields Cover.__struct__() |> Map.from_struct() |> Map.keys()
  @source_fields Source.__struct__() |> Map.from_struct() |> Map.keys()

  @doc "Builds a typed public book projection from the bounded public catalog read model."
  def book!(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> Map.take(@book_fields)
      |> Map.update(:formats, [], &Enum.map(&1, fn format -> format!(format) end))
      |> Map.update(:sources, [], &Enum.map(&1, fn source -> source!(source) end))
      |> Map.update(:source, nil, &maybe_source/1)
      |> Map.update(:cover, nil, &maybe_cover/1)
      |> Map.update(:authors, [], &Enum.map(&1, fn contributor -> contributor!(contributor) end))
      |> Map.update(
        :translators,
        [],
        &Enum.map(&1, fn contributor -> contributor!(contributor) end)
      )
      |> Map.update(:contributors_by_role, %{}, &contributors_by_role!/1)

    struct!(Book, attrs)
  end

  def format!(attrs) when is_map(attrs) do
    Format
    |> struct!(attrs |> Map.take(@format_fields) |> Map.update(:identifiers, [], &List.wrap/1))
  end

  def contributor!(attrs) when is_map(attrs) do
    struct!(Contributor, Map.take(attrs, @contributor_fields))
  end

  def source!(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> Map.take(@source_fields)
      |> Map.update(:field_sources, %{}, &(&1 || %{}))
      |> Map.update(:provider_permissions, %{}, &(&1 || %{}))

    struct!(Source, attrs)
  end

  def cover!(attrs) when is_map(attrs) do
    struct!(Cover, Map.take(attrs, @cover_fields))
  end

  defp maybe_source(nil), do: nil
  defp maybe_source(source), do: source!(source)

  defp maybe_cover(nil), do: nil
  defp maybe_cover(cover), do: cover!(cover)

  defp contributors_by_role!(contributors_by_role) when is_map(contributors_by_role) do
    Map.new(contributors_by_role, fn {role, contributors} ->
      {role, Enum.map(contributors || [], fn contributor -> contributor!(contributor) end)}
    end)
  end
end
