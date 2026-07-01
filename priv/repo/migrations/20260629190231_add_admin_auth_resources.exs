defmodule Hiraeth.Repo.Migrations.AddAdminAuthResources do
  use Ecto.Migration

  def change do
    create table(:admin_users, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :email, :text, null: false
      add :role, :text, null: false, default: "admin"
      add :disabled?, :boolean, null: false, default: false
      add :last_login_at, :utc_datetime
      add :audit_metadata, :map, null: false, default: %{}
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create unique_index(:admin_users, [:email], name: "admin_users_unique_admin_email_index")
    create index(:admin_users, [:role], name: "admin_users_role_index")
    create index(:admin_users, [:disabled?], name: "admin_users_disabled_index")

    create constraint(:admin_users, :admin_users_role_check,
             check: "role IN ('owner', 'admin', 'viewer')"
           )

    create table(:admin_session_tokens, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true

      add :admin_user_id,
          references(:admin_users,
            column: :id,
            name: "admin_session_tokens_admin_user_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :delete_all
          ),
          null: false

      add :purpose, :text, null: false
      add :token_hash, :text, null: false
      add :expires_at, :utc_datetime, null: false
      add :consumed_at, :utc_datetime
      add :created_by_email, :text
      add :created_ip, :text
      add :user_agent, :text
      add :audit_metadata, :map, null: false, default: %{}
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create unique_index(:admin_session_tokens, [:token_hash],
             name: "admin_session_tokens_unique_admin_session_token_hash_index"
           )

    create index(:admin_session_tokens, [:admin_user_id],
             name: "admin_session_tokens_admin_user_id_index"
           )

    create index(:admin_session_tokens, [:purpose], name: "admin_session_tokens_purpose_index")

    create index(:admin_session_tokens, [:expires_at],
             name: "admin_session_tokens_expires_at_index"
           )

    create index(:admin_session_tokens, [:consumed_at],
             name: "admin_session_tokens_consumed_at_index"
           )

    create constraint(:admin_session_tokens, :admin_session_tokens_purpose_check,
             check: "purpose IN ('invite', 'session')"
           )

    create constraint(:admin_session_tokens, :admin_session_tokens_hash_check,
             check: "token_hash ~ '^[a-f0-9]{64}$'"
           )
  end
end
