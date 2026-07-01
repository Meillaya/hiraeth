defmodule Hiraeth.Accounts.AdminUser do
  use Ash.Resource,
    domain: Hiraeth.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "admin_users"
    repo Hiraeth.Repo

    custom_indexes do
      index :role, name: "admin_users_role_index"
      index :disabled?, name: "admin_users_disabled_index"
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :email, :string do
      allow_nil? false
      public? true
    end

    attribute :role, :string do
      allow_nil? false
      default "admin"
      public? true
    end

    attribute :disabled?, :boolean do
      allow_nil? false
      default false
      public? true
    end

    attribute :last_login_at, :utc_datetime do
      public? true
    end

    attribute :audit_metadata, :map do
      allow_nil? false
      default %{}
      public? false
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :admin_session_tokens, Hiraeth.Accounts.AdminSessionToken
  end

  identities do
    identity :unique_admin_email, [:email]
  end

  validations do
    validate match(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/)
    validate one_of(:role, ["owner", "admin", "viewer"])
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:email, :role, :disabled?, :audit_metadata]
    end

    update :set_role do
      require_atomic? false
      accept [:role]
    end

    update :disable do
      require_atomic? false
      accept []
      change set_attribute(:disabled?, true)
    end

    update :enable do
      require_atomic? false
      accept []
      change set_attribute(:disabled?, false)
    end

    update :record_login do
      require_atomic? false
      accept [:last_login_at]
    end
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      description "Only the trusted admin auth system can manage admin identities in v1."
      authorize_if actor_attribute_equals(:admin_auth_system?, true)
    end
  end
end
