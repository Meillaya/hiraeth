defmodule HiraethWeb.PublishersLive do
  use HiraethWeb, :live_view

  alias HiraethWeb.CatalogComponents
  alias HiraethWeb.PublicCatalog

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Curated Publishers")}
  end

  @impl true
  def handle_params(%{"slug" => slug}, _uri, socket) do
    {:noreply,
     socket
     |> assign(:page_title, "Publisher")
     |> assign_publisher(PublicCatalog.publisher(slug))}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:page_title, "Curated Publishers")
     |> stream(:publishers, PublicCatalog.publishers(),
       reset: true,
       dom_id: &"publisher-#{&1.slug}"
     )}
  end

  @impl true
  def render(%{live_action: :show} = assigns), do: render_show(assigns)
  def render(assigns), do: render_index(assigns)

  defp render_index(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_scope={%{}}>
      <div id="publishers-shell" class="space-y-12">
        <div class="border-b border-[#E7E2D8] dark:border-[#2E2A27] pb-5">
          <span class="font-mono text-xs uppercase tracking-wider text-stone-500">Editorial Directory</span>
          <h1 class="font-serif text-3xl font-medium tracking-tight text-stone-900 dark:text-stone-100 mt-1">
            Curated Presses
          </h1>
          <p class="text-sm text-stone-600 dark:text-stone-400 mt-2">
            Public publishers currently represented by sourced local catalog metadata.
          </p>
        </div>

        <div id="publishers-grid" phx-update="stream" class="grid grid-cols-1 md:grid-cols-2 gap-8">
          <article
            :for={{dom_id, pub} <- @streams.publishers}
            id={dom_id}
            class="bg-[#F5F2EB] dark:bg-[#1C1917] p-8 border border-[#E7E2D8] dark:border-[#2E2A27] rounded-sm space-y-4 flex flex-col justify-between"
          >
            <div class="space-y-3">
              <h2 class="font-serif text-2xl font-medium text-[#8C2D19] dark:text-[#E05A47]">
                <.link navigate={~p"/publishers/#{pub.slug}"} class="hover:underline">{pub.name}</.link>
              </h2>
              <p
                :if={pub[:description]}
                class="text-sm text-stone-700 dark:text-stone-300 leading-relaxed font-sans pt-2"
              >
                {pub.description}
              </p>
            </div>

            <div class="border-t border-[#E7E2D8] dark:border-[#2E2A27] pt-4 flex justify-between items-center text-xs font-mono text-stone-500">
              <span>{pub.editions_count} Cataloged Books</span>
              <.link
                navigate={~p"/publishers/#{pub.slug}"}
                class="text-[#8C2D19] dark:text-[#E05A47] hover:underline font-bold"
              >
                Browse Imprint →
              </.link>
            </div>
          </article>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp render_show(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_scope={%{}}>
      <div id="publisher-detail-shell" class="space-y-10">
        <%= if @publisher do %>
          <div class="border-b border-[#E7E2D8] dark:border-[#2E2A27] pb-5 space-y-2">
            <.link
              navigate={~p"/publishers"}
              class="font-mono text-xs uppercase tracking-wider text-stone-500 hover:underline"
            >← Publishers</.link>
            <h1
              id="publisher-title"
              class="font-serif text-4xl font-medium tracking-tight text-stone-900 dark:text-stone-100"
            >
              {@publisher.name}
            </h1>
            <p
              :if={@publisher[:description]}
              class="max-w-2xl text-sm text-stone-600 dark:text-stone-400 leading-relaxed"
            >
              {@publisher.description}
            </p>
          </div>

          <section
            id="publisher-context"
            class="grid gap-4 rounded-sm border border-[#E7E2D8] bg-[#F5F2EB]/70 p-5 text-sm text-stone-700 dark:border-[#2E2A27] dark:bg-[#1C1917]/70 dark:text-stone-300 sm:grid-cols-3"
          >
            <div>
              <p class="font-mono text-[10px] uppercase tracking-wider text-stone-500 dark:text-stone-400">
                Sourced shelf
              </p>
              <p class="mt-1 font-serif text-xl text-stone-950 dark:text-stone-50">
                {@publisher.editions_count} sourced books
              </p>
            </div>
            <div :if={facet_text(format_facets(@publisher.editions))}>
              <p class="font-mono text-[10px] uppercase tracking-wider text-stone-500 dark:text-stone-400">
                Formats
              </p>
              <p class="mt-1">{facet_text(format_facets(@publisher.editions))}</p>
            </div>
            <div :if={facet_text(language_facets(@publisher.editions))}>
              <p class="font-mono text-[10px] uppercase tracking-wider text-stone-500 dark:text-stone-400">
                Languages
              </p>
              <p class="mt-1 font-mono text-xs uppercase tracking-wider">
                {facet_text(language_facets(@publisher.editions))}
              </p>
            </div>
          </section>

          <section id="publisher-editions" class="space-y-6">
            <h2 class="font-serif text-2xl font-medium">Cataloged editions</h2>
            <%= if @publisher.editions_count == 0 do %>
              <CatalogComponents.empty_state
                id="publisher-no-editions"
                title="No editions are attached"
                message="No editions are attached to this publisher yet. The publisher record is public, but the shelf stays empty until sourced editions are imported or curated."
                action_label="Back to publishers"
                action_path="/publishers"
              />
            <% else %>
              <div
                id="publisher-editions-stream"
                phx-update="stream"
                class="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 gap-6"
              >
                <CatalogComponents.edition_card
                  :for={{dom_id, edition} <- @streams.publisher_editions}
                  dom_id={dom_id}
                  edition={edition}
                  id_prefix="publisher-edition"
                />
              </div>
            <% end %>
          </section>
        <% else %>
          <CatalogComponents.empty_state
            id="publisher-not-found"
            title="No publisher matches"
            message="No publisher matches that slug. The archive kept you on the publisher shelf so you can choose another press."
            action_label="Back to publishers"
            action_path="/publishers"
          />
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  defp assign_publisher(socket, nil) do
    socket
    |> assign(:publisher, nil)
    |> stream(:publisher_editions, [], reset: true)
  end

  defp assign_publisher(socket, publisher) do
    socket
    |> assign(:publisher, publisher)
    |> stream(:publisher_editions, publisher.editions, reset: true)
  end

  defp format_facets(editions), do: facet_values(editions, :format)

  defp language_facets(editions), do: facet_values(editions, :language_code)

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
