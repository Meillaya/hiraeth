defmodule Hiraeth.RealCatalog.Slug do
  @moduledoc false

  def slugify(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.normalize(:nfd)
    |> String.replace(~r/[^\p{L}\p{N}\s-]/u, "")
    |> String.replace(~r/\s+/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
  end
end
