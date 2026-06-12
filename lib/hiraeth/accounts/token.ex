defmodule Hiraeth.Accounts.Token do
  use Ash.Resource,
    domain: Hiraeth.Accounts,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAuthentication.TokenResource],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "tokens"
    repo Hiraeth.Repo
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end

    policy always() do
      forbid_if always()
    end
  end
end
