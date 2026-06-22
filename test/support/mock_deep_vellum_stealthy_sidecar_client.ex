defmodule Hiraeth.Support.MockDeepVellumStealthySidecarClient do
  @moduledoc false

  def health(_opts \\ []) do
    {:ok, %{status: "ok", scrapling: true}}
  end

  def scrape(%{provider: "deep_vellum_official_store"}, _opts \\ []) do
    {:ok, %{records: Hiraeth.Support.DeepVellumStealthyFixture.records()}}
  end
end
