defmodule Hiraeth.Audit do
  @moduledoc "Ash domain: the audit event resource registry."

  use Ash.Domain

  resources do
    resource Hiraeth.Audit.AuditEvent
  end
end
