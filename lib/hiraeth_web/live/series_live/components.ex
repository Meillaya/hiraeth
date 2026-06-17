defmodule HiraethWeb.SeriesLive.Components do
  use HiraethWeb, :html

  alias HiraethWeb.CatalogComponents

  attr :series_empty?, :boolean, required: true
  attr :streams, :map, required: true

  def index(assigns) do
    ~H"""
    <div id="series-shell" class="archive-wash space-y-12 pb-12">
      <header class="border-b qi-divider pb-6">
        <div class="flex flex-col gap-4 md:flex-row md:items-end md:justify-between">
          <div>
            <p class="qi-kicker text-[var(--hiraeth-thread)]">Collections by press</p>
            <h1 class="mt-2 font-serif text-4xl font-light tracking-tight text-[var(--hiraeth-ink)] sm:text-5xl">
              Series & Collections
            </h1>
          </div>
          <p class="qi-muted max-w-xl font-serif text-base italic leading-relaxed md:text-right">
            Sequence positions appear only once a source supplies them; otherwise the shelf stays unnumbered.
          </p>
        </div>
      </header>

      <div id="series-rows" phx-update="stream" class="grid grid-cols-1 gap-6 lg:grid-cols-3">
        <CatalogComponents.empty_state
          :if={@series_empty?}
          id="series-empty"
          title="No sourced series yet"
          message="Series and collections appear only after sourced memberships are imported. The shelf will not invent unsourced collection names."
        />
        <article
          :for={{dom_id, ser} <- @streams.series_list}
          id={dom_id}
          class="qi-card flex flex-col justify-between space-y-5 p-6"
        >
          <div class="space-y-3">
            <div class="flex items-start justify-between gap-4">
              <p :if={ser[:publisher]} class="qi-kicker text-[var(--hiraeth-thread)]">
                {ser.publisher}
              </p>
              <p class="font-mono text-xs text-[var(--hiraeth-muted)]">
                {ser.editions_count} editions
              </p>
            </div>
            <h2 class="font-serif text-3xl font-light leading-tight text-[var(--hiraeth-ink)]">
              <.link
                navigate={~p"/series/#{ser.slug}"}
                class="qi-focus rounded-sm hover:text-[var(--hiraeth-thread)]"
              >
                {ser.title}
              </.link>
            </h2>
          </div>
          <div class="border-t qi-divider pt-4">
            <.link
              navigate={~p"/series/#{ser.slug}"}
              class="qi-action-link font-mono text-xs uppercase tracking-wider"
            >
              Open series shelf →
            </.link>
          </div>
        </article>
      </div>
    </div>
    """
  end

  attr :series, :map, default: nil
  attr :streams, :map, required: true

  def show(assigns) do
    ~H"""
    <div id="series-detail-shell" class="archive-wash space-y-10 pb-12">
      <%= if @series do %>
        <header class="border-b qi-divider pb-7">
          <.link
            navigate={~p"/series"}
            class="qi-action-link font-mono text-xs uppercase tracking-wider"
          >← Series</.link>
          <div class="mt-6 grid gap-6 lg:grid-cols-[minmax(0,1fr)_22rem] lg:items-end">
            <div class="space-y-3">
              <p :if={@series[:publisher]} class="qi-kicker text-[var(--hiraeth-thread)]">
                {@series.publisher}
              </p>
              <h1
                id="series-title"
                class="font-serif text-5xl font-light tracking-tight text-[var(--hiraeth-ink)]"
              >
                {@series.title}
              </h1>
              <p class="qi-muted max-w-2xl font-serif text-lg italic leading-relaxed">
                A sourced shelf grouped by declared series membership. Hiraeth does not infer missing sequence positions.
              </p>
            </div>
            <.context_panel series={@series} />
          </div>
        </header>

        <section id="series-editions" class="space-y-6">
          <div class="flex items-baseline justify-between border-b qi-divider pb-4">
            <h2 class="font-serif text-2xl font-normal text-[var(--hiraeth-ink)]">Series editions</h2>
            <span class="font-mono text-xs text-[var(--hiraeth-muted)]">{@series.editions_count} records</span>
          </div>
          <div
            :if={@series[:unknown_order?]}
            id="series-unknown-order"
            class="qi-panel-soft border-[var(--hiraeth-thread)]/35 p-4 text-sm text-[var(--hiraeth-ink)]"
          >
            <p class="qi-kicker text-[var(--hiraeth-thread)]">Sequence order is not sourced</p>
            <p class="qi-muted mt-2 font-serif leading-relaxed">
              Sequence order is not sourced for every work in this series yet. Editions remain visible, but Hiraeth will not invent numbering.
            </p>
          </div>
          <div
            id="series-editions-stream"
            phx-update="stream"
            class="grid grid-cols-2 gap-6 sm:grid-cols-3 lg:grid-cols-4"
          >
            <CatalogComponents.edition_card
              :for={{dom_id, edition} <- @streams.series_editions}
              dom_id={dom_id}
              edition={edition}
              id_prefix="series-detail-edition"
            />
          </div>
        </section>
      <% else %>
        <CatalogComponents.empty_state
          id="series-not-found"
          title="No series matches"
          message="No series matches that slug. Choose another collection from the series shelf."
          action_label="Back to series"
          action_path="/series"
        />
      <% end %>
    </div>
    """
  end

  defp context_panel(assigns) do
    ~H"""
    <section
      id="series-context"
      class="qi-panel-soft grid gap-4 p-5 text-sm sm:grid-cols-3 lg:grid-cols-1"
    >
      <div>
        <p class="qi-label">Collection</p>
        <p class="mt-1 font-serif text-xl text-[var(--hiraeth-ink)]">{@series.title}</p>
      </div>
      <div>
        <p class="qi-label">Sourced shelf</p>
        <p class="mt-1 font-serif text-xl text-[var(--hiraeth-ink)]">
          {@series.editions_count} sourced books
        </p>
      </div>
      <div :if={facet_text(format_facets(@series.editions))}>
        <p class="qi-label">Formats</p>
        <p class="qi-muted mt-1">{facet_text(format_facets(@series.editions))}</p>
      </div>
    </section>
    """
  end

  defp format_facets(editions), do: facet_values(editions, :format)

  defp facet_values(editions, key) do
    editions
    |> Enum.map(&Map.get(&1, key))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp facet_text([]), do: nil
  defp facet_text(values), do: Enum.join(values, ", ")
end
