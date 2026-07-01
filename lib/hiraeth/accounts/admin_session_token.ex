defmodule Hiraeth.Accounts.AdminSessionToken do
  use Ash.Resource,
    domain: Hiraeth.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "admin_session_tokens"
    repo Hiraeth.Repo

    custom_indexes do
      index :admin_user_id, name: "admin_session_tokens_admin_user_id_index"
      index :purpose, name: "admin_session_tokens_purpose_index"
      index :expires_at, name: "admin_session_tokens_expires_at_index"
      index :consumed_at, name: "admin_session_tokens_consumed_at_index"
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :purpose, :string do
      allow_nil? false
      public? true
    end

    attribute :token_hash, :string do
      allow_nil? false
      public? false
    end

    attribute :expires_at, :utc_datetime do
      allow_nil? false
      public? true
    end

    attribute :consumed_at, :utc_datetime do
      public? true
    end

    attribute :created_by_email, :string do
      public? false
    end

    attribute :created_ip, :string do
      public? false
    end

    attribute :user_agent, :string do
      public? false
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
    belongs_to :admin_user, Hiraeth.Accounts.AdminUser do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_admin_session_token_hash, [:token_hash]
  end

  validations do
    validate one_of(:purpose, ["invite", "session"])
    validate match(:token_hash, ~r/^[a-f0-9]{64}$/)
  end

  actions do
    defaults [:read]

    create :create_invite do
      accept [
        :admin_user_id,
        :token_hash,
        :expires_at,
        :created_by_email,
        :created_ip,
        :user_agent,
        :audit_metadata
      ]

      change set_attribute(:purpose, "invite")
    end

    create :create_session do
      accept [
        :admin_user_id,
        :token_hash,
        :expires_at,
        :created_ip,
        :user_agent,
        :audit_metadata
      ]

      change set_attribute(:purpose, "session")
    end

    update :consume do
      require_atomic? false
      accept [:consumed_at]
    end

    update :revoke do
      require_atomic? false
      accept [:consumed_at]
    end
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      description "Only the trusted admin auth system can manage hashed admin tokens."
      authorize_if actor_attribute_equals(:admin_auth_system?, true)
    end
  end
end
