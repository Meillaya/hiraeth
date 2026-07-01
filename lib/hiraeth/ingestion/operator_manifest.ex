defmodule Hiraeth.Ingestion.OperatorManifest do
  @moduledoc false

  alias Hiraeth.Ingestion.ProviderManifest

  def default_path(provider), do: Path.join(ProviderManifest.default_dir(), "#{provider}.json")

  def load(manifest_path) do
    try do
      {:ok, ProviderManifest.load!(manifest_path)}
    rescue
      error -> {:error, "manifest load failed: #{Exception.message(error)}"}
    end
  end

  def ensure_provider_matches(provider, manifest) do
    if provider == manifest.provider do
      :ok
    else
      {:error,
       "provider #{inspect(provider)} does not match manifest provider #{inspect(manifest.provider)}"}
    end
  end
end
