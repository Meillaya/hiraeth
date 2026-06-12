defmodule Hiraeth.Accounts do
  use Ash.Domain

  resources do
    resource Hiraeth.Accounts.User
    resource Hiraeth.Accounts.Token
  end
end
