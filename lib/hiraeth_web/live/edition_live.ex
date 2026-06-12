defmodule HiraethWeb.EditionLive do
  use HiraethWeb, :live_view

  alias HiraethWeb.CatalogComponents
  alias HiraethWeb.PublicCatalog

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Edition")}
  end

  @impl true
  def handle_params(%{"slug" => slug}, _uri, socket) do
    edition = PublicCatalog.edition(slug)

    {:noreply,
     socket
     |> assign(:edition, edition)
     |> assign(:page_title, if(edition, do: edition.title, else: "Edition not found"))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_scope={%{}}>
      <div id="edition-detail-shell" class="space-y-10">
        <%= if @edition do %>
          <.link
            navigate={~p"/browse"}
            class="font-mono text-xs uppercase tracking-wider text-stone-500 hover:underline"
          >← Browse catalog</.link>

          <div class="grid grid-cols-1 lg:grid-cols-12 gap-10 items-start">
            <aside class="lg:col-span-4 space-y-4">
              <CatalogComponents.book_cover book={@edition} class="max-w-sm mx-auto" />
              <p
                :if={!@edition[:cover]}
                id="missing-cover-note"
                class="rounded-sm border border-[#E7E2D8] bg-[#F5F2EB] p-3 text-center text-[10px] font-mono uppercase tracking-wider text-stone-600 dark:border-[#2E2A27] dark:bg-[#1C1917] dark:text-stone-400"
              >
                No sourced cover asset is attached; typographic cover fallback is shown.
              </p>
            </aside>

            <section class="lg:col-span-8 space-y-8">
              <div class="space-y-3 border-b border-[#E7E2D8] dark:border-[#2E2A27] pb-6">
                <p
                  :if={@edition[:publisher]}
                  class="font-mono text-xs uppercase tracking-wider text-[#8C2D19] dark:text-[#E05A47]"
                >
                  {@edition.publisher}
                </p>
                <h1
                  id="edition-title"
                  class="font-serif text-4xl md:text-5xl font-medium tracking-tight text-stone-900 dark:text-stone-100"
                >
                  {@edition.title}
                </h1>
                <p
                  :if={@edition[:subtitle]}
                  class="font-serif italic text-xl text-stone-600 dark:text-stone-400"
                >
                  {@edition.subtitle}
                </p>
                <p
                  :if={@edition[:author]}
                  id="edition-contributors"
                  class="text-sm text-stone-600 dark:text-stone-400"
                >
                  by {@edition.author}
                </p>
              </div>

              <div id="edition-identifiers" class="sr-only">
                {Enum.join(@edition.identifiers, " ")}
              </div>

              <section
                :if={@edition[:description]}
                id="book-description"
                class="prose prose-stone dark:prose-invert max-w-none"
              >
                <h2 class="font-serif text-xl font-medium">Description</h2>
                <p>{@edition.description}</p>
              </section>

              <section
                :if={Enum.any?(@edition[:editorial_praise] || [])}
                id="book-editorial-praise"
                class="space-y-3"
              >
                <h2 class="font-serif text-xl font-medium">Editorial praise</h2>
                <blockquote
                  :for={praise <- @edition.editorial_praise}
                  class="border-l-2 border-[#8C2D19] pl-4 text-sm text-stone-700 dark:text-stone-300"
                >
                  <p>{praise["quote"] || praise[:quote]}</p>
                  <footer class="mt-2 font-mono text-[10px] uppercase tracking-wider">
                    {praise["source"] || praise[:source]}
                  </footer>
                </blockquote>
              </section>

              <.link
                :if={@edition[:storefront_url]}
                id="book-storefront-cta"
                href={@edition.storefront_url}
                class="inline-flex font-mono text-xs uppercase tracking-wider text-[#8C2D19] dark:text-[#E05A47] hover:underline font-bold"
              >
                Publisher page
              </.link>

              <CatalogComponents.metadata_table book={@edition} />
              <CatalogComponents.provenance_badge source={@edition.source} />
            </section>
          </div>
        <% else %>
          <CatalogComponents.empty_state
            id="edition-not-found"
            title="No edition matches"
            message="No edition matches that slug. The archive did not fabricate a placeholder record."
            action_label="Back to browse"
            action_path="/browse"
          />
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
