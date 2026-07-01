defmodule Hiraeth.Catalog.PublicProjection.Contributor do
  @moduledoc "Contributor summary exposed on public catalog cards and detail pages."

  @behaviour Access

  @enforce_keys [:name]
  defstruct [:id, :contribution_id, :position, :role, :name, :slug]

  defdelegate fetch(projection, key), to: Hiraeth.Catalog.PublicProjection.Access

  defdelegate get_and_update(projection, key, function),
    to: Hiraeth.Catalog.PublicProjection.Access

  defdelegate pop(projection, key), to: Hiraeth.Catalog.PublicProjection.Access
end
