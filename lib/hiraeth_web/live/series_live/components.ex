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
            <p class="qi-muted mt-4 max-w-2xl font-serif text-lg italic leading-relaxed">
              Publisher-led shelves for reading across a line, imprint, or collection.
            </p>
          </div>
        </div>
      </header>

      <div id="series-rows" phx-update="stream" class="divide-y divide-[var(--hiraeth-line)]">
        <CatalogComponents.empty_state
          :if={@series_empty?}
          id="series-empty"
          title="No series shelves yet"
          message="Series and collections will appear here as the archive grows."
        />
        <article
          :for={{dom_id, ser} <- @streams.series_list}
          id={dom_id}
          class="grid gap-8 py-10 lg:grid-cols-[18rem_minmax(0,1fr)] lg:items-start"
        >
          <div class="space-y-4">
            <p :if={ser[:publisher]} class="qi-kicker text-[var(--hiraeth-thread)]">
              {ser.publisher}
            </p>
            <h2 class="font-serif text-4xl font-light leading-tight tracking-tight text-[var(--hiraeth-ink)]">
              <.link
                navigate={~p"/series/#{ser.slug}"}
                class="qi-focus rounded-sm hover:text-[var(--hiraeth-thread)]"
              >
                {ser.title}
              </.link>
            </h2>
            <p class="sr-only">{ser.editions_count} books in this shelf.</p>
            <.link
              navigate={~p"/series/#{ser.slug}"}
              class="qi-action-link inline-flex font-mono text-xs uppercase tracking-wider"
            >
              Open series shelf
            </.link>
          </div>
          <div class="grid grid-cols-2 gap-5 sm:grid-cols-4">
            <CatalogComponents.edition_card
              :for={edition <- ser[:preview_editions] || []}
              edition={edition}
              id_prefix={"series-preview-#{ser.slug}"}
            />
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
                A shelf for reading this collection across the archive.
              </p>
            </div>
            <.context_panel series={@series} />
          </div>
        </header>

        <section id="series-editions" class="space-y-6">
          <div class="flex items-baseline justify-between border-b qi-divider pb-4">
            <h2 class="font-serif text-2xl font-normal text-[var(--hiraeth-ink)]">Series editions</h2>
            <span class="sr-only">{@series.editions_count} books</span>
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
    <section id="series-context" class="qi-panel-soft grid gap-4 p-5 text-sm sm:grid-cols-2">
      <div>
        <p class="qi-label">Collection</p>
        <p class="mt-1 font-serif text-xl text-[var(--hiraeth-ink)]">{@series.title}</p>
      </div>
      <div :if={facet_text(format_facets(@series.editions))}>
        <p class="qi-label">Formats</p>
        <p class="qi-muted mt-1">{facet_text(format_facets(@series.editions))}</p>
      </div>
    </section>
    """
  end

  defp format_facets(editions) do
    editions
    |> Enum.flat_map(fn edition ->
      edition
      |> Map.get(:formats, [])
      |> Enum.map(&(&1[:format_label] || &1[:format]))
    end)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp facet_text([]), do: nil
  defp facet_text(values), do: Enum.join(values, ", ")
end
