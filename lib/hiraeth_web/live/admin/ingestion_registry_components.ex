defmodule HiraethWeb.Admin.IngestionRegistryComponents do
  @moduledoc false

  use HiraethWeb, :html

  import HiraethWeb.Admin.IngestionFormat

  attr :providers, :any, required: true
  attr :selected_provider, :any, default: nil

  def provider_registry(assigns) do
    ~H"""
    <section id="admin-provider-registry-panel" class="qi-panel overflow-hidden">
      <div class="border-b qi-divider p-5">
        <p class="qi-label">Provider registry</p>
        <p class="mt-2 text-sm leading-6 text-[var(--hiraeth-muted)]">
          Pause and resume change the provider schedule flag, then refresh the run ledger from persisted Ash resources.
        </p>
      </div>

      <div
        id="admin-provider-registry"
        phx-update="stream"
        class="divide-y divide-[var(--hiraeth-line)]"
      >
        <article id="admin-provider-empty" class="hidden only:block p-5">
          <div class="qi-empty p-5 text-sm text-[var(--hiraeth-muted)]">
            No provider sources have been registered yet.
          </div>
        </article>
        <article
          :for={{dom_id, provider} <- @providers}
          id={dom_id}
          class={[
            "qi-row grid gap-4 p-5 transition duration-200 lg:grid-cols-[minmax(0,1fr)_auto]",
            @selected_provider && @selected_provider.id == provider.id &&
              "bg-[var(--hiraeth-thread-soft)]"
          ]}
        >
          <div class="min-w-0 space-y-3">
            <div>
              <.link
                id={"admin-provider-link-#{provider.id}"}
                patch={~p"/admin/ingestion/providers/#{provider.id}"}
                class="qi-action-link font-semibold text-[var(--hiraeth-ink)]"
              >
                {provider.provider_name}
              </.link>
              <p class="mt-1 font-mono text-[11px] text-[var(--hiraeth-label)]">
                {provider.stable_source_key}
              </p>
              <p :if={provider.base_uri} class="mt-2 break-all text-xs text-[var(--hiraeth-muted)]">
                {provider.base_uri}
              </p>
            </div>

            <dl class="grid gap-3 text-xs sm:grid-cols-3">
              <div>
                <dt class="qi-label">Mode</dt>
                <dd class="mt-1 font-mono text-[var(--hiraeth-ink)]">{provider.source_kind}</dd>
                <dd class="mt-1 text-[var(--hiraeth-muted)]">{provider.ingestion_mode}</dd>
              </div>
              <div>
                <dt class="qi-label">Schedule</dt>
                <dd class="mt-1">
                  <span class={status_badge_class(provider.enabled?)}>
                    {if provider.enabled?, do: "Enabled", else: "Paused"}
                  </span>
                </dd>
              </div>
              <div>
                <dt class="qi-label">Action</dt>
                <dd class="mt-1">
                  <.provider_action provider={provider} />
                </dd>
              </div>
            </dl>
          </div>
        </article>
      </div>
    </section>
    """
  end

  attr :provider, :any, required: true

  defp provider_action(assigns) do
    ~H"""
    <button
      :if={@provider.enabled?}
      id={"admin-pause-provider-#{@provider.id}"}
      type="button"
      class="qi-button-secondary whitespace-nowrap"
      phx-click="pause-provider"
      phx-value-provider-id={@provider.id}
    >
      Pause
    </button>
    <button
      :if={!@provider.enabled?}
      id={"admin-resume-provider-#{@provider.id}"}
      type="button"
      class="qi-button whitespace-nowrap"
      phx-click="resume-provider"
      phx-value-provider-id={@provider.id}
    >
      Resume
    </button>
    """
  end

  attr :selected_provider, :any, default: nil
  attr :can_mutate?, :boolean, default: false

  def provider_detail(assigns) do
    ~H"""
    <div :if={@selected_provider} id="admin-provider-detail" class="qi-panel space-y-5 p-6">
      <div class="flex flex-col gap-4 border-b qi-divider pb-5 lg:flex-row lg:items-start lg:justify-between">
        <div class="space-y-2">
          <p class="qi-label">Selected source</p>
          <h2 class="font-serif text-3xl font-light text-[var(--hiraeth-ink)]">
            {@selected_provider.provider_name}
          </h2>
          <p id="admin-selected-provider-key" class="font-mono text-xs text-[var(--hiraeth-label)]">
            {@selected_provider.stable_source_key}
          </p>
        </div>
        <div id="admin-selected-provider-status" class="space-y-3 text-left lg:text-right">
          <span class={status_badge_class(@selected_provider.enabled?)}>
            {if @selected_provider.enabled?, do: "Enabled", else: "Paused"}
          </span>
          <div id="admin-selected-provider-action">
            <.selected_provider_action provider={@selected_provider} />
          </div>
          <p :if={!@can_mutate?} class="text-xs text-[var(--hiraeth-muted)]">
            Pause and resume require owner or admin role.
          </p>
        </div>
      </div>

      <dl id="admin-provider-metadata" class="grid gap-4 text-sm sm:grid-cols-2">
        <.metadata_item label="Manifest" value={@selected_provider.manifest_uri || "Not recorded"} />
        <.metadata_item label="Allowed hosts" value={hosts_text(@selected_provider.allowed_hosts)} />
        <.metadata_item
          label="Rate limit"
          value={limit_text(@selected_provider.rate_limit_per_minute, "per minute")}
        />
        <.metadata_item label="Max bytes" value={limit_text(@selected_provider.max_bytes, "bytes")} />
      </dl>
    </div>

    <div :if={!@selected_provider} id="admin-provider-detail-empty" class="qi-empty p-6">
      <p class="qi-label">No provider selected</p>
      <p class="mt-2 text-sm text-[var(--hiraeth-muted)]">
        Register a provider source to review schedule state and run history.
      </p>
    </div>
    """
  end

  attr :provider, :any, required: true

  defp selected_provider_action(assigns) do
    ~H"""
    <button
      :if={@provider.enabled?}
      id={"admin-selected-pause-provider-#{@provider.id}"}
      type="button"
      class="qi-button-secondary whitespace-nowrap"
      phx-click="pause-provider"
      phx-value-provider-id={@provider.id}
    >
      Pause
    </button>
    <button
      :if={!@provider.enabled?}
      id={"admin-selected-resume-provider-#{@provider.id}"}
      type="button"
      class="qi-button whitespace-nowrap"
      phx-click="resume-provider"
      phx-value-provider-id={@provider.id}
    >
      Resume
    </button>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true

  defp metadata_item(assigns) do
    ~H"""
    <div class="border-t qi-divider pt-3">
      <dt class="qi-label">{@label}</dt>
      <dd class="mt-2 break-all text-[var(--hiraeth-muted)]">{@value}</dd>
    </div>
    """
  end

  attr :phase_statuses, :list, required: true

  def phase_status_panel(assigns) do
    ~H"""
    <section id="admin-phase-status-panel" class="qi-panel p-6">
      <div class="mb-5 flex flex-col gap-2 border-b qi-divider pb-4">
        <p class="qi-label">Phase status</p>
        <p class="text-sm text-[var(--hiraeth-muted)]">
          Latest phase audit events for the selected source.
        </p>
      </div>
      <div id="admin-phase-statuses" class="grid gap-3 md:grid-cols-2">
        <div
          :if={@phase_statuses == []}
          id="admin-phase-status-empty"
          class="qi-empty p-4 text-sm text-[var(--hiraeth-muted)] md:col-span-2"
        >
          No phase events have been recorded for this source.
        </div>
        <div
          :for={phase <- @phase_statuses}
          id={"admin-phase-#{phase.dom_id}"}
          class="border border-[var(--hiraeth-line)] bg-[var(--hiraeth-warm)] p-4"
        >
          <div class="flex items-start justify-between gap-3">
            <p class="font-mono text-xs font-semibold text-[var(--hiraeth-ink)]">{phase.name}</p>
            <span class={event_badge_class(phase.status)}>{phase.status}</span>
          </div>
          <p class="mt-2 text-xs text-[var(--hiraeth-muted)]">{phase.message}</p>
        </div>
      </div>
    </section>
    """
  end
end
