defmodule Hiraeth.Search do
  use Ash.Domain

  resources do
    resource Hiraeth.Search.Result do
      define :search, args: [:query]
    end
  end
end
