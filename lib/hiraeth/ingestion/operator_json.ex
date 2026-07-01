defmodule Hiraeth.Ingestion.OperatorJSON do
  @moduledoc false

  def print(payload) do
    payload
    |> stringify_keys()
    |> Jason.encode!()
    |> Mix.shell().info()
  end

  def stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  def stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  def stringify_keys(value), do: value
end
