defmodule HiraethWeb.HomeLive do
  use HiraethWeb, :live_view

  alias HiraethWeb.CatalogComponents
  alias HiraethWeb.PublicCatalog

  @impl true
  def mount(_params, _session, socket) do
    editions = PublicCatalog.books()
    spotlight = List.first(editions)
    recent = Enum.slice(editions, 1, 4)

    {:ok,
     socket
     |> assign(:page_title, "Quiet Editorial Archive")
     |> assign(:spotlight, spotlight)
     |> stream(:recent, recent)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_scope={%{}}>
      <div id="home-shell" class="space-y-16">
        <div class="text-center max-w-2xl mx-auto space-y-4 pt-4">
          <div class="text-stone-300 dark:text-stone-700 text-3xl font-serif">❧</div>
          <h1 class="font-serif text-4xl md:text-5xl font-light tracking-tight text-stone-900 dark:text-stone-100">
            Hiraeth Editorial Archive
          </h1>
          <p class="font-serif italic text-stone-600 dark:text-stone-400 text-lg leading-relaxed">
            A quiet space dedicated to traceable metadata, typography, and independent book catalogs.
          </p>
        </div>

        <%= if @spotlight do %>
          <div class="grid grid-cols-1 md:grid-cols-12 gap-8 md:gap-12 items-center border-y border-[#E7E2D8] dark:border-[#2E2A27] py-12">
            <div class="md:col-span-5 max-w-xs mx-auto md:w-full">
              <CatalogComponents.book_cover
                book={@spotlight}
                class="shadow-md shadow-stone-900/10 dark:shadow-none"
              />
            </div>

            <div id="home-spotlight" class="md:col-span-7 space-y-6">
              <div>
                <span class="font-mono text-xs uppercase tracking-wider text-stone-500">Spotlight Book</span>
                <h2 class="font-serif text-3xl font-medium tracking-tight mt-1 text-stone-900 dark:text-stone-100">
                  {@spotlight.title}
                </h2>
                <p
                  :if={@spotlight[:author]}
                  class="font-sans text-sm italic text-stone-600 dark:text-stone-400 mt-1"
                >
                  by {@spotlight.author}
                </p>
              </div>

              <div class="space-y-2 border-t border-[#E7E2D8] dark:border-[#2E2A27] pt-4 text-xs font-mono text-stone-500">
                <div :if={@spotlight[:publisher]}>
                  Publisher:
                  <span class="text-stone-800 dark:text-stone-300 font-sans">{@spotlight.publisher}</span>
                </div>
                <div :if={@spotlight[:isbn]}>ISBN: <span>{@spotlight.isbn}</span></div>
                <div :if={@spotlight[:source]}>
                  Source: <span>{@spotlight.source.provider}</span>
                </div>
              </div>

              <div class="flex gap-4">
                <.link
                  navigate={~p"/browse"}
                  class="inline-flex items-center gap-1 font-mono text-xs uppercase tracking-wider text-[#8C2D19] dark:text-[#E05A47] hover:underline font-bold"
                >
                  Examine Catalog →
                </.link>
                <.link
                  navigate={~p"/books/#{@spotlight.slug}"}
                  class="inline-flex items-center gap-1 font-mono text-xs uppercase tracking-wider text-stone-500 hover:text-stone-800 dark:hover:text-stone-200 hover:underline"
                >
                  Book Detail →
                </.link>
              </div>
            </div>
          </div>
        <% else %>
          <CatalogComponents.empty_state
            id="home-empty"
            title="No public catalog records"
            message="No public catalog records are available yet. Seed or import sourced editions before opening the archive."
            action_label="Browse empty catalog"
            action_path="/browse"
          />
        <% end %>

        <div id="recent-acquisitions" class="space-y-6">
          <div class="flex items-baseline justify-between border-b border-[#E7E2D8] dark:border-[#2E2A27] pb-3">
            <h2 class="font-serif text-2xl font-medium tracking-tight">Recent Acquisitions</h2>
            <.link
              navigate={~p"/browse"}
              class="font-mono text-xs uppercase tracking-wider text-stone-500 hover:text-stone-800 dark:hover:text-stone-200 hover:underline"
            >
              View All →
            </.link>
          </div>

          <div id="recent-books" phx-update="stream" class="grid grid-cols-2 sm:grid-cols-4 gap-6">
            <CatalogComponents.edition_card
              :for={{dom_id, edition} <- @streams.recent}
              dom_id={dom_id}
              edition={edition}
              id_prefix="recent-book"
            />
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
