defmodule Hiraeth.Repo.Migrations.RemoveAccountsAuthTables do
  use Ecto.Migration

  def up do
    execute "ALTER TABLE IF EXISTS curation_overrides DROP CONSTRAINT IF EXISTS curation_overrides_reviewer_id_fkey"

    execute "ALTER TABLE IF EXISTS audit_events DROP CONSTRAINT IF EXISTS audit_events_actor_id_fkey"

    alter table(:curation_overrides) do
      modify :reviewer_id, :uuid, null: true
    end

    alter table(:audit_events) do
      modify :actor_id, :uuid, null: true
    end

    drop_if_exists table(:tokens)
    drop_if_exists table(:users)
  end

  def down do
    :ok
  end
end
