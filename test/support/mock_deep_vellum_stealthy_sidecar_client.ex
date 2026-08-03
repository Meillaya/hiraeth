defmodule Hiraeth.Support.MockDeepVellumStealthySidecarClient do
  @moduledoc false

  alias Hiraeth.Support.DeepVellumStealthyFixture

  def health(_opts \\ []) do
    {:ok, %{status: "ok", scrapling: true}}
  end

  def scrape(%{provider: "deep_vellum_official_store"}, _opts \\ []) do
    {:ok, %{records: DeepVellumStealthyFixture.records()}}
  end
end
