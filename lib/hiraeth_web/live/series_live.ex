defmodule HiraethWeb.SeriesLive do
  use HiraethWeb, :live_view

  alias HiraethWeb.CatalogComponents
  alias HiraethWeb.PublicCatalog

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Series & Imprints")}
  end

  @impl true
  def handle_params(%{"slug" => slug}, _uri, socket) do
    {:noreply,
     socket
     |> assign(:page_title, "Series")
     |> assign_series(PublicCatalog.series_by_slug(slug))}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:page_title, "Series & Imprints")
     |> stream(:series_list, PublicCatalog.series(), reset: true, dom_id: &"series-#{&1.slug}")}
  end

  @impl true
  def render(%{live_action: :show} = assigns), do: render_show(assigns)
  def render(assigns), do: render_index(assigns)

  defp render_index(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_scope={%{}}>
      <div id="series-shell" class="space-y-12">
        <div class="border-b border-[#E7E2D8] dark:border-[#2E2A27] pb-5">
          <span class="font-mono text-xs uppercase tracking-wider text-stone-500">Curated Imprints</span>
          <h1 class="font-serif text-3xl font-medium tracking-tight text-stone-900 dark:text-stone-100 mt-1">
            Series & Collections
          </h1>
          <p class="text-sm text-stone-600 dark:text-stone-400 mt-2">
            Archived titles organized by sourced editorial series.
          </p>
        </div>

        <div id="series-rows" phx-update="stream" class="space-y-12">
          <section
            :for={{dom_id, ser} <- @streams.series_list}
            id={dom_id}
            class="space-y-6 border-b border-[#E7E2D8]/50 dark:border-[#2E2A27]/50 pb-8 last:border-b-0"
          >
            <div class="space-y-1 max-w-2xl">
              <span
                :if={ser[:publisher]}
                class="font-mono text-[10px] uppercase tracking-wider text-[#8C2D19] dark:text-[#E05A47]"
              >
                {ser.publisher}
              </span>
              <h2 class="font-serif text-xl font-medium italic text-stone-900 dark:text-stone-100">
                <.link navigate={~p"/series/#{ser.slug}"} class="hover:underline">{ser.title}</.link>
              </h2>
              <p class="text-xs text-stone-500 font-mono">{ser.editions_count} cataloged editions</p>
            </div>

            <div class="text-xs font-mono text-stone-600 dark:text-stone-400">
              <.link
                navigate={~p"/series/#{ser.slug}"}
                class="text-[#8C2D19] dark:text-[#E05A47] hover:underline font-bold"
              >
                Open series shelf →
              </.link>
            </div>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp render_show(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_scope={%{}}>
      <div id="series-detail-shell" class="space-y-10">
        <%= if @series do %>
          <div class="border-b border-[#E7E2D8] dark:border-[#2E2A27] pb-5 space-y-2">
            <.link
              navigate={~p"/series"}
              class="font-mono text-xs uppercase tracking-wider text-stone-500 hover:underline"
            >← Series</.link>
            <p
              :if={@series[:publisher]}
              class="font-mono text-xs uppercase tracking-wider text-[#8C2D19] dark:text-[#E05A47]"
            >
              {@series.publisher}
            </p>
            <h1
              id="series-title"
              class="font-serif text-4xl font-medium tracking-tight text-stone-900 dark:text-stone-100"
            >
              {@series.title}
            </h1>
          </div>

          <section id="series-editions" class="space-y-6">
            <h2 class="font-serif text-2xl font-medium">Series editions</h2>
            <div
              :if={@series[:unknown_order?]}
              id="series-unknown-order"
              class="rounded-sm border border-amber-300 bg-amber-50 p-4 text-sm text-amber-900 dark:border-amber-900/70 dark:bg-amber-950/30 dark:text-amber-200"
            >
              <p class="font-mono text-[10px] uppercase tracking-wider">
                Sequence order is not sourced
              </p>
              <p class="mt-1">
                Sequence order is not sourced for every work in this series yet. Editions remain visible, but Hiraeth will not invent numbering.
              </p>
            </div>
            <div
              id="series-editions-stream"
              phx-update="stream"
              class="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 gap-6"
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
    </Layouts.app>
    """
  end

  defp assign_series(socket, nil) do
    socket
    |> assign(:series, nil)
    |> stream(:series_editions, [], reset: true)
  end

  defp assign_series(socket, series) do
    socket
    |> assign(:series, series)
    |> stream(:series_editions, series.editions, reset: true)
  end
end
