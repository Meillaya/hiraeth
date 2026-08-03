defmodule Hiraeth.Search do
  @moduledoc "Ash domain: read-model search results exposed to the public catalog search page."

  use Ash.Domain

  resources do
    resource Hiraeth.Search.Result do
      define :search, args: [:query]
    end
  end
end
