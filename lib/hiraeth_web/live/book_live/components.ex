defmodule HiraethWeb.BookLive.Components do
  use HiraethWeb, :html

  alias HiraethWeb.CatalogComponents

  attr :book, :map, default: nil

  def detail(assigns) do
    ~H"""
    <div id="book-detail-shell" class="archive-wash space-y-10 pb-12">
      <%= if @book do %>
        <.link
          navigate={~p"/browse"}
          class="qi-action-link font-mono text-xs uppercase tracking-wider"
        >
          ← Browse catalog
        </.link>

        <article class="grid grid-cols-1 gap-10 lg:grid-cols-[21rem_minmax(0,1fr)] lg:items-start lg:gap-16">
          <aside class="space-y-4 lg:sticky lg:top-24">
            <CatalogComponents.book_cover
              book={@book}
              class="mx-auto max-w-sm"
              loading="eager"
              fetchpriority="high"
              variant="hero"
            />
            <p
              :if={!@book[:cover]}
              id="missing-cover-note"
              class="qi-panel-soft p-3 text-center text-[10px] font-mono uppercase tracking-wider text-[var(--hiraeth-muted)]"
            >
              No sourced cover asset is attached; typographic cover fallback is shown.
            </p>
          </aside>

          <section class="min-w-0 space-y-8">
            <header class="border-b qi-divider pb-7">
              <p :if={@book[:publisher]} class="qi-kicker text-[var(--hiraeth-thread)]">
                {@book.publisher}
              </p>
              <h1
                id="book-title"
                class="mt-4 max-w-3xl font-serif text-5xl font-light leading-none tracking-tight text-[var(--hiraeth-ink)] md:text-6xl"
              >
                {@book.title}
              </h1>
              <p :if={@book[:subtitle]} class="qi-muted mt-4 font-serif text-xl italic">
                {@book.subtitle}
              </p>
              <div class="mt-5 space-y-1 text-sm font-medium text-[var(--hiraeth-ink)]">
                <p :if={role_names(@book[:authors])} id="book-authors">
                  by {role_names(@book.authors)}
                </p>
                <p :if={role_names(@book[:translators])} id="book-translators" class="qi-muted">
                  translated by {role_names(@book.translators)}
                </p>
                <p :if={format_summary(@book[:formats])} id="book-format-summary" class="qi-muted">
                  Formats: {format_summary(@book.formats)}
                </p>
              </div>
            </header>

            <div id="book-identifiers" class="sr-only">{Enum.join(@book.identifiers, " ")}</div>

            <section
              :if={@book[:description]}
              id="book-description"
              class="max-w-2xl border-l-2 border-[var(--hiraeth-thread)] py-1 pl-5 font-serif text-xl font-light leading-9 text-[var(--hiraeth-ink)]"
            >
              <h2 class="qi-label mb-2 text-[10px]">Description</h2>
              <p>{@book.description}</p>
            </section>

            <section
              :if={Enum.any?(@book[:editorial_praise] || [])}
              id="book-editorial-praise"
              class="qi-panel-soft max-w-2xl space-y-4 p-5"
            >
              <h2 class="font-serif text-xl font-normal text-[var(--hiraeth-ink)]">
                Editorial praise
              </h2>
              <blockquote
                :for={praise <- @book.editorial_praise}
                class="border-l-2 border-[var(--hiraeth-thread)] pl-4 font-serif text-lg italic leading-8 text-[var(--hiraeth-ink)]"
              >
                <p>{praise["quote"] || praise[:quote]}</p>
                <footer class="mt-2 font-mono text-[10px] not-italic uppercase tracking-wider text-[var(--hiraeth-muted)]">
                  {praise["source"] || praise[:source]}
                </footer>
              </blockquote>
            </section>

            <section
              :if={Enum.any?(@book[:review_links] || [])}
              id="book-review-links"
              class="qi-panel-soft max-w-2xl space-y-4 p-5"
            >
              <h2 class="font-serif text-xl font-normal text-[var(--hiraeth-ink)]">
                Reviews
              </h2>
              <article
                :for={review <- @book.review_links}
                class="border-t border-[var(--hiraeth-line)] pt-4 first:border-t-0 first:pt-0"
              >
                <.link
                  href={review["source_uri"] || review[:source_uri]}
                  class="qi-action-link font-mono text-xs uppercase tracking-wider"
                >
                  {review["source"] || review[:source]}
                </.link>
                <p
                  :if={review["excerpt"] || review[:excerpt]}
                  class="mt-2 font-serif text-lg italic leading-8 text-[var(--hiraeth-ink)]"
                >
                  “{review["excerpt"] || review[:excerpt]}”
                </p>
              </article>
            </section>

            <div
              :if={Enum.empty?(@book[:review_links] || [])}
              id="book-review-gap"
              class="qi-panel-soft max-w-2xl p-4 font-mono text-[10px] uppercase tracking-wider text-[var(--hiraeth-muted)]"
            >
              No review links are recorded for this title.
            </div>

            <section id="book-formats" class="space-y-4">
              <div class="flex items-baseline justify-between border-b qi-divider pb-3">
                <h2 class="font-serif text-xl font-normal text-[var(--hiraeth-ink)]">
                  Formats / editions
                </h2>
                <span class="font-mono text-xs text-[var(--hiraeth-muted)]">{length(@book.formats)} records</span>
              </div>
              <div class="divide-y divide-[var(--hiraeth-line)] border-y qi-divider">
                <div
                  :for={format <- @book.formats}
                  id={"book-format-#{format.edition_slug}"}
                  class="grid gap-3 py-4 text-sm sm:grid-cols-[9rem_minmax(0,1fr)_12rem]"
                >
                  <div class="font-mono text-xs uppercase tracking-wider text-[var(--hiraeth-muted)]">
                    {format.format_label}
                  </div>
                  <div class="space-y-1">
                    <p
                      :if={format.identifiers != []}
                      class="break-all font-mono text-xs text-[var(--hiraeth-ink)]"
                    >
                      {Enum.join(format.identifiers, ", ")}
                    </p>
                    <p
                      :if={format.identifiers == []}
                      class="font-mono text-xs text-[var(--hiraeth-muted)]"
                    >
                      No ISBN recorded · source identity route retained
                    </p>
                    <p
                      :if={format_detail_text(format)}
                      class="qi-muted font-mono text-[11px] uppercase tracking-wider"
                    >
                      {format_detail_text(format)}
                    </p>
                  </div>
                  <p class="font-mono text-xs text-[var(--hiraeth-muted)] sm:text-right">
                    {if format.published_on,
                      do: Calendar.strftime(format.published_on, "%Y-%m-%d"),
                      else: "Date unknown"}
                  </p>
                </div>
              </div>
            </section>

            <.link
              :if={@book[:storefront_url]}
              id="book-storefront-cta"
              href={@book.storefront_url}
              class="qi-button qi-focus"
            >
              Publisher page
            </.link>

            <p
              :if={!@book[:storefront_url]}
              id="book-purchase-link-gap"
              class="qi-panel-soft inline-flex max-w-2xl p-3 font-mono text-[10px] uppercase tracking-wider text-[var(--hiraeth-muted)]"
            >
              No provider purchase link is recorded for this title.
            </p>

            <CatalogComponents.metadata_table book={@book} />
          </section>
        </article>
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

  defp format_detail_text(format) do
    [
      format[:language_code],
      page_count_text(format[:page_count]),
      dimensions_text(format[:dimensions])
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp page_count_text(nil), do: nil
  defp page_count_text(page_count), do: "#{page_count} pages"

  defp dimensions_text(nil), do: nil

  defp dimensions_text(%{height_mm: height, width_mm: width, depth_mm: depth}) do
    [height, width, depth]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      dimensions -> Enum.join(dimensions, " × ") <> " mm"
    end
  end

  defp dimensions_text(_dimensions), do: nil

  defp format_summary(formats) when is_list(formats) do
    formats
    |> Enum.map(& &1[:format_label])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.join(", ")
    |> case do
      "" -> nil
      summary -> summary
    end
  end

  defp format_summary(_formats), do: nil
end
