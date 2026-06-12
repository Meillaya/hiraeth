defmodule Hiraeth.Audit do
  use Ash.Domain

  resources do
    resource Hiraeth.Audit.AuditEvent
  end
end
