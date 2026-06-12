defmodule HiraethWeb.BookLive do
  use HiraethWeb, :live_view

  alias HiraethWeb.CatalogComponents
  alias HiraethWeb.PublicCatalog

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Book")}
  end

  @impl true
  def handle_params(%{"slug" => slug}, _uri, socket) do
    book = PublicCatalog.book(slug)

    {:noreply,
     socket
     |> assign(:book, book)
     |> assign(:page_title, if(book, do: book.title, else: "Book not found"))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_scope={%{}}>
      <div id="book-detail-shell" class="space-y-10">
        <%= if @book do %>
          <.link
            navigate={~p"/browse"}
            class="font-mono text-xs uppercase tracking-wider text-stone-500 hover:underline"
          >← Browse catalog</.link>

          <div class="grid grid-cols-1 lg:grid-cols-12 gap-10 items-start">
            <aside class="lg:col-span-4 space-y-4">
              <CatalogComponents.book_cover book={@book} class="max-w-sm mx-auto" />
              <p
                :if={!@book[:cover]}
                id="missing-cover-note"
                class="rounded-sm border border-[#E7E2D8] bg-[#F5F2EB] p-3 text-center text-[10px] font-mono uppercase tracking-wider text-stone-600 dark:border-[#2E2A27] dark:bg-[#1C1917] dark:text-stone-400"
              >
                No sourced cover asset is attached; typographic cover fallback is shown.
              </p>
            </aside>

            <section class="lg:col-span-8 space-y-8">
              <div class="space-y-3 border-b border-[#E7E2D8] dark:border-[#2E2A27] pb-6">
                <p
                  :if={@book[:publisher]}
                  class="font-mono text-xs uppercase tracking-wider text-[#8C2D19] dark:text-[#E05A47]"
                >
                  {@book.publisher}
                </p>
                <h1
                  id="book-title"
                  class="font-serif text-4xl md:text-5xl font-medium tracking-tight text-stone-900 dark:text-stone-100"
                >
                  {@book.title}
                </h1>
                <p
                  :if={@book[:subtitle]}
                  class="font-serif italic text-xl text-stone-600 dark:text-stone-400"
                >
                  {@book.subtitle}
                </p>
                <p
                  :if={@book[:author]}
                  id="book-contributors"
                  class="text-sm text-stone-600 dark:text-stone-400"
                >
                  by {@book.author}
                </p>
              </div>

              <div id="book-identifiers" class="sr-only">
                {Enum.join(@book.identifiers, " ")}
              </div>

              <section
                :if={@book[:description]}
                id="book-description"
                class="prose prose-stone dark:prose-invert max-w-none"
              >
                <h2 class="font-serif text-xl font-medium">Description</h2>
                <p>{@book.description}</p>
              </section>

              <section id="book-formats" class="space-y-3">
                <h2 class="font-serif text-xl font-medium">Formats / editions</h2>
                <div class="divide-y divide-[#E7E2D8]/70 dark:divide-[#2E2A27]/70 rounded-sm border border-[#E7E2D8] dark:border-[#2E2A27]">
                  <div
                    :for={format <- @book.formats}
                    id={"book-format-#{format.edition_slug}"}
                    class="grid gap-2 p-4 sm:grid-cols-3 text-sm"
                  >
                    <div class="font-mono text-xs uppercase tracking-wider text-stone-500">
                      {format.format_label}
                    </div>
                    <div class="font-mono text-xs text-stone-700 dark:text-stone-300">
                      {Enum.join(format.identifiers, ", ")}
                    </div>
                    <div class="text-stone-600 dark:text-stone-400">
                      {if format.published_on,
                        do: Calendar.strftime(format.published_on, "%Y-%m-%d"),
                        else: "Date unknown"}
                    </div>
                  </div>
                </div>
              </section>

              <section
                :if={Enum.any?(@book[:editorial_praise] || [])}
                id="book-editorial-praise"
                class="space-y-3"
              >
                <h2 class="font-serif text-xl font-medium">Editorial praise</h2>
                <blockquote
                  :for={praise <- @book.editorial_praise}
                  class="border-l-2 border-[#8C2D19] pl-4 text-sm text-stone-700 dark:text-stone-300"
                >
                  <p>{praise["quote"] || praise[:quote]}</p>
                  <footer class="mt-2 font-mono text-[10px] uppercase tracking-wider">
                    {praise["source"] || praise[:source]}
                  </footer>
                </blockquote>
              </section>

              <.link
                :if={@book[:storefront_url]}
                id="book-storefront-cta"
                href={@book.storefront_url}
                class="inline-flex font-mono text-xs uppercase tracking-wider text-[#8C2D19] dark:text-[#E05A47] hover:underline font-bold"
              >
                Publisher page
              </.link>

              <CatalogComponents.metadata_table book={@book} />
              <CatalogComponents.provenance_badge source={@book.source} />
            </section>
          </div>
        <% else %>
          <CatalogComponents.empty_state
            id="book-not-found"
            title="No book matches"
            message="No book matches that slug. The archive did not fabricate a placeholder record."
            action_label="Back to browse"
            action_path="/browse"
          />
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
