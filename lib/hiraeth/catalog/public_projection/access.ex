defmodule Hiraeth.Catalog.PublicProjection.Access do
  @moduledoc false

  def fetch(projection, key) do
    projection
    |> Map.from_struct()
    |> Map.fetch(key)
  end

  def get_and_update(projection, key, function) do
    {value, updated_attrs} =
      projection
      |> Map.from_struct()
      |> Map.get_and_update(key, function)

    {value, struct(projection.__struct__, updated_attrs)}
  end

  def pop(projection, key) do
    {value, updated_attrs} =
      projection
      |> Map.from_struct()
      |> Map.pop(key)

    {value, struct(projection.__struct__, updated_attrs)}
  end
end
