defmodule Hiraeth.Accounts.User do
  use Ash.Resource,
    domain: Hiraeth.Accounts,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAuthentication],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "users"
    repo Hiraeth.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :email, :ci_string do
      allow_nil? false
      public? true
    end

    attribute :hashed_password, :string do
      allow_nil? false
      sensitive? true
    end

    attribute :display_name, :string do
      public? true
    end

    attribute :admin?, :boolean do
      allow_nil? false
      default false
      public? true
    end
  end

  relationships do
    has_many :audit_events, Hiraeth.Audit.AuditEvent, destination_attribute: :actor_id
  end

  identities do
    identity :unique_email, [:email]
  end

  actions do
    defaults [:read, :destroy]

    read :get_by_subject do
      description "Get a user by the subject claim in a JWT."
      argument :subject, :string, allow_nil?: false
      get? true
      prepare AshAuthentication.Preparations.FilterBySubject
    end

    create :seed_admin do
      description "Create an admin user from trusted seed/test code only."
      accept [:email, :display_name]

      argument :password, :string do
        allow_nil? false
        sensitive? true
        constraints min_length: 8
      end

      change set_attribute(:admin?, true)
      change set_context(%{strategy_name: :password})
      change AshAuthentication.Strategy.Password.HashPasswordChange
    end

    update :update do
      accept [:email, :display_name, :admin?]
    end
  end

  authentication do
    tokens do
      enabled? true
      token_resource Hiraeth.Accounts.Token
      store_all_tokens? true
      require_token_presence_for_authentication? true

      signing_secret fn _, _ ->
        Application.fetch_env(:hiraeth, :token_signing_secret)
      end
    end

    strategies do
      password :password do
        identity_field :email
        registration_enabled? false
      end
    end
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end

    policy action(:seed_admin) do
      description "Seed action is only available when callers explicitly disable authorization."
      forbid_if always()
    end

    policy action([:sign_in_with_password, :sign_in_with_token, :get_by_subject]) do
      description "Authentication read actions must be callable before an admin actor exists."
      authorize_if always()
    end

    policy action(:read) do
      description "Admins can read account records; authentication internals bypass this policy."
      authorize_if actor_attribute_equals(:admin?, true)
    end

    policy action_type([:create, :update, :destroy]) do
      description "Only admin actors can mutate account records outside authentication internals."
      authorize_if actor_attribute_equals(:admin?, true)
    end
  end
end
