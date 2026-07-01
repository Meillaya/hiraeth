defmodule HiraethWeb.Admin.IngestionShellComponents do
  @moduledoc false

  use HiraethWeb, :html

  attr :current_admin_user, :any, required: true
  attr :title, :string, default: "Provider registry and run timeline"

  attr :deck, :string,
    default:
      "A source-forward ledger for ingestion schedules, phase progress, retained artifacts, and operator controls."

  def admin_header(assigns) do
    ~H"""
    <header id="admin-ingestion-heading" class="space-y-4 border-b qi-divider pb-6">
      <div class="flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
        <div class="max-w-3xl space-y-3">
          <p class="qi-kicker text-[var(--hiraeth-thread)]">Operator console</p>
          <h1 class="font-serif text-4xl font-light tracking-tight text-[var(--hiraeth-ink)] md:text-5xl">
            {@title}
          </h1>
          <p class="font-serif text-lg italic leading-relaxed text-[var(--hiraeth-muted)]">
            {@deck}
          </p>
        </div>
        <div id="admin-ingestion-operator" class="qi-panel min-w-64 space-y-2 p-4">
          <p class="qi-label">Signed operator</p>
          <p class="truncate font-mono text-sm text-[var(--hiraeth-ink)]">
            {@current_admin_user.email}
          </p>
          <p class="text-xs text-[var(--hiraeth-muted)]">
            Role
            <span class="font-semibold text-[var(--hiraeth-ink)]">{@current_admin_user.role}</span>
          </p>
        </div>
      </div>
    </header>
    """
  end

  attr :provider_count, :integer, required: true
  attr :enabled_count, :integer, required: true
  attr :run_count, :integer, required: true
  attr :artifact_count, :integer, required: true

  def summary_cards(assigns) do
    ~H"""
    <section id="admin-ingestion-summary" class="grid gap-4 md:grid-cols-4">
      <.summary_card
        id="admin-provider-count"
        label="Providers"
        value={@provider_count}
        note="registered sources"
      />
      <.summary_card
        id="admin-enabled-count"
        label="Enabled"
        value={@enabled_count}
        note="scheduled for ticks"
      />
      <.summary_card id="admin-run-count" label="Runs" value={@run_count} note="selected source" />
      <.summary_card
        id="admin-artifact-count"
        label="Artifacts"
        value={@artifact_count}
        note="retained pointers"
      />
    </section>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :note, :string, required: true

  defp summary_card(assigns) do
    ~H"""
    <div id={@id} class="qi-panel p-4">
      <p class="qi-label">{@label}</p>
      <p class="mt-2 font-serif text-3xl text-[var(--hiraeth-ink)]">{@value}</p>
      <p class="mt-1 text-xs text-[var(--hiraeth-muted)]">{@note}</p>
    </div>
    """
  end
end
