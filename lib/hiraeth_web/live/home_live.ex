defmodule HiraethWeb.HomeLive do
  use HiraethWeb, :live_view

  alias HiraethWeb.CatalogComponents
  alias HiraethWeb.PublicCatalog

  @impl true
  def mount(_params, _session, socket) do
    catalog = PublicCatalog.book_page(%{"sort" => "recently_added"}, 1, 160)
    spotlight = spotlight_entry(catalog.entries)

    recent =
      catalog.entries
      |> Enum.reject(&(&1[:slug] == spotlight[:slug]))
      |> Enum.take(3)

    {:ok,
     socket
     |> assign(:page_title, "Quiet Editorial Archive")
     |> assign(:catalog_count, catalog.total_count)
     |> assign(:spotlight, spotlight)
     |> stream(:recent, recent)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={%{}}
      catalog_count={@catalog_count}
    >
      <main id="home-shell" class="archive-wash space-y-10 pb-8 md:space-y-12">
        <section class="space-y-5 pt-0">
          <p class="qi-kicker text-[var(--hiraeth-thread)]">A quiet editorial archive</p>
          <div class="max-w-4xl space-y-4">
            <h1 class="text-balance font-serif text-5xl font-light leading-[1.02] tracking-tight text-[var(--hiraeth-ink)] md:text-[4.125rem]">
              Traceable metadata for independent presses.
            </h1>
            <p class="max-w-2xl font-serif text-xl font-light italic leading-relaxed text-[var(--hiraeth-muted)] md:text-2xl">
              A curated pilot of independent publisher catalogs — showing only what is sourced, and naming where every record came from.
            </p>
          </div>
        </section>

        <%= if @spotlight do %>
          <section
            id="home-spotlight"
            class="grid grid-cols-1 items-start gap-10 border-t qi-divider pt-8 lg:grid-cols-[minmax(0,1fr)_20rem] lg:gap-16"
          >
            <div class="space-y-5">
              <div class="space-y-4">
                <p class="qi-kicker text-[var(--hiraeth-thread)]">
                  Spotlight volume — {@spotlight.publisher || "Publisher unknown"}
                </p>
                <div class="space-y-2">
                  <h2 class="text-balance font-serif text-5xl font-light leading-none tracking-tight text-[var(--hiraeth-ink)] md:text-[4rem]">
                    {@spotlight.title}
                  </h2>
                  <p
                    :if={role_names(@spotlight[:authors])}
                    class="font-serif text-xl font-light italic text-[var(--hiraeth-muted)]"
                  >
                    {role_names(@spotlight.authors)}
                  </p>
                  <p :if={role_names(@spotlight[:translators])} class="qi-muted text-sm">
                    translated by {role_names(@spotlight.translators)}
                  </p>
                </div>
                <p
                  :if={@spotlight[:description]}
                  class="max-w-2xl font-serif text-base font-light leading-7 text-[var(--hiraeth-ink)]"
                >
                  {description_excerpt(@spotlight.description, 260)}
                </p>
              </div>

              <div
                :if={praise_quote(@spotlight)}
                class="max-w-xl border-l border-[var(--hiraeth-thread)] py-1 pl-5"
              >
                <p class="font-serif text-xl italic text-[var(--hiraeth-ink)]">
                  “{praise_quote(@spotlight)}”
                </p>
                <p class="qi-label mt-2">
                  {praise_source(@spotlight) || "Sourced praise"}
                </p>
              </div>

              <div class="grid max-w-2xl grid-cols-1 gap-x-10 sm:grid-cols-2">
                <.spotlight_meta label="Publisher" value={@spotlight[:publisher]} />
                <.spotlight_meta label="Formats" value={format_line(@spotlight)} />
                <.spotlight_meta label="ISBN-13" value={identifier_line(@spotlight)} mono />
                <.spotlight_meta label="Published" value={published_date(@spotlight)} mono />
              </div>

              <p :if={@spotlight[:source]} class="qi-label max-w-2xl break-words">
                Source · {@spotlight.source.provider} · imported {imported_date(@spotlight.source)}
              </p>

              <div class="flex flex-wrap items-center gap-5">
                <.link navigate={~p"/browse"} class="qi-button qi-focus">
                  Examine catalog
                </.link>
                <.link
                  navigate={~p"/books/#{@spotlight.slug}"}
                  class="qi-action-link qi-focus font-semibold"
                >
                  Edition detail →
                </.link>
              </div>
            </div>

            <div class="mx-auto w-full max-w-xs lg:max-w-none">
              <.link navigate={~p"/books/#{@spotlight.slug}"} class="group block qi-focus rounded-sm">
                <CatalogComponents.book_cover
                  book={@spotlight}
                  loading="eager"
                  fetchpriority="high"
                  variant="hero"
                />
              </.link>
            </div>
          </section>
        <% else %>
          <CatalogComponents.empty_state
            id="home-empty"
            title="No public catalog records"
            message="No public catalog records are available yet. Seed or import sourced editions before opening the archive."
            action_label="Browse empty catalog"
            action_path="/browse"
          />
        <% end %>

        <section id="recent-acquisitions" class="space-y-7">
          <div class="flex items-baseline justify-between gap-6 border-b qi-divider pb-4">
            <div>
              <p class="qi-kicker text-[var(--hiraeth-thread)]">Recently imported</p>
              <h2 class="mt-2 font-serif text-3xl font-normal tracking-tight text-[var(--hiraeth-ink)]">
                Recent acquisitions
              </h2>
            </div>
            <.link
              navigate={~p"/browse?sort=recently_added"}
              class="qi-action-link qi-focus text-xs font-semibold uppercase tracking-[0.16em]"
            >
              View all →
            </.link>
          </div>

          <div
            id="recent-books"
            phx-update="stream"
            class="grid grid-cols-1 gap-8 sm:grid-cols-2 lg:grid-cols-3"
          >
            <CatalogComponents.edition_card
              :for={{dom_id, edition} <- @streams.recent}
              dom_id={dom_id}
              edition={edition}
              id_prefix="recent-book"
            />
          </div>
        </section>
      </main>
    </Layouts.app>
    """
  end

  defp spotlight_entry(entries) do
    Enum.find(entries, &cached_cover?/1) || List.first(entries)
  end

  defp cached_cover?(%{cover: cover}) when is_map(cover) do
    local_cache_url?(cover[:public_url]) || local_cache_url?(cover[:thumbnail_url])
  end

  defp cached_cover?(_entry), do: false

  defp local_cache_url?(url) when is_binary(url), do: String.starts_with?(url, "/covers/cache/")
  defp local_cache_url?(_url), do: false

  attr :label, :string, required: true
  attr :value, :string, default: nil
  attr :mono, :boolean, default: false

  def spotlight_meta(assigns) do
    ~H"""
    <div :if={present?(@value)} class="border-t qi-divider py-4">
      <dt class="qi-label">{@label}</dt>
      <dd class={[
        "mt-1 text-[var(--hiraeth-ink)]",
        @mono && "font-mono text-sm",
        !@mono && "font-serif text-lg"
      ]}>
        {@value}
      </dd>
    </div>
    """
  end

  defp role_names(contributors) when is_list(contributors) do
    contributors
    |> Enum.map(& &1[:name])
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
    |> case do
      "" -> nil
      names -> names
    end
  end

  defp role_names(_contributors), do: nil

  defp format_line(book) do
    book
    |> Map.get(:formats, [])
    |> Enum.map(&(&1[:format_label] || &1[:format]))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.join(" · ")
    |> blank_to_nil()
  end

  defp identifier_line(book) do
    book
    |> Map.get(:identifiers, [])
    |> Enum.join(" · ")
    |> blank_to_nil()
  end

  defp published_date(%{published_on: %Date{} = date}), do: Calendar.strftime(date, "%Y-%m-%d")
  defp published_date(_book), do: nil

  defp imported_date(%{imported_at: %DateTime{} = date}), do: Calendar.strftime(date, "%Y-%m-%d")
  defp imported_date(_source), do: "unknown date"

  defp praise_quote(book) do
    case spotlight_praise(book) do
      nil -> nil
      praise -> praise[:quote] || praise["quote"]
    end
  end

  defp praise_source(book) do
    case spotlight_praise(book) do
      nil -> nil
      praise -> praise[:source] || praise["source"]
    end
  end

  defp spotlight_praise(%{praise: [%{} = praise | _]}), do: praise
  defp spotlight_praise(%{editorial_praise: [%{} = praise | _]}), do: praise
  defp spotlight_praise(_book), do: nil

  defp description_excerpt(description, length) when is_binary(description) do
    description
    |> String.trim()
    |> String.slice(0, length)
  end

  defp present?(value), do: value not in [nil, "", []]

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
