defmodule Hiraeth.Repo.Migrations.AddProviderSourcesCadenceHours do
  use Ecto.Migration

  def change do
    alter table(:provider_sources) do
      add :cadence_hours, :integer, null: false, default: 24
    end
  end
end
