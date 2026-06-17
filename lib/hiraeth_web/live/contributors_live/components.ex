defmodule HiraethWeb.ContributorsLive.Components do
  use HiraethWeb, :html

  alias HiraethWeb.CatalogComponents

  attr :role, :string, default: nil
  attr :streams, :map, required: true

  def index(assigns) do
    ~H"""
    <div id="contributors-shell" class="archive-wash space-y-10 pb-12">
      <header class="border-b qi-divider pb-6">
        <div class="flex flex-col gap-5 md:flex-row md:items-end md:justify-between">
          <div>
            <p class="qi-kicker text-[var(--hiraeth-thread)]">Role-aware directory</p>
            <h1 class="mt-2 font-serif text-4xl font-light tracking-tight text-[var(--hiraeth-ink)] sm:text-5xl">
              {title(@role)}
            </h1>
            <p class="qi-muted mt-3 max-w-2xl font-serif text-lg italic leading-relaxed">
              Authors, translators, and other sourced contributors represented in the public catalog.
            </p>
          </div>
          <nav
            id="contributor-roles"
            class="flex flex-wrap gap-2 text-xs font-mono uppercase tracking-wider"
            aria-label="Contributor role filters"
          >
            <.link navigate={~p"/contributors"} class={role_link_class(@role, nil)}>All</.link>
            <.link navigate={~p"/contributors?role=author"} class={role_link_class(@role, "author")}>Authors</.link>
            <.link
              navigate={~p"/contributors?role=translator"}
              class={role_link_class(@role, "translator")}
            >Translators</.link>
          </nav>
        </div>
      </header>

      <div id="contributors-grid" phx-update="stream" class="divide-y divide-[var(--hiraeth-line)]">
        <article
          :for={{dom_id, contributor} <- @streams.contributors}
          id={dom_id}
          class="qi-row grid gap-5 py-7 transition duration-200 md:grid-cols-[4rem_minmax(0,1fr)_10rem] md:items-center"
        >
          <p class="qi-label text-xs">{count_label(contributor.books_count)}</p>
          <div class="min-w-0 space-y-3">
            <div class="flex flex-wrap gap-2" aria-label="Contributor roles">
              <span
                :for={role <- contributor.roles}
                class="rounded-sm border border-[var(--hiraeth-line-strong)] px-2 py-1 font-mono text-[10px] uppercase tracking-wider text-[var(--hiraeth-muted)]"
              >
                {role}
              </span>
            </div>
            <h2 class="font-serif text-3xl font-light leading-tight text-[var(--hiraeth-ink)]">
              <.link
                navigate={~p"/contributors/#{contributor.slug}"}
                class="qi-focus rounded-sm hover:text-[var(--hiraeth-thread)]"
              >
                {contributor.name}
              </.link>
            </h2>
          </div>
          <.link
            navigate={~p"/contributors/#{contributor.slug}"}
            class="qi-action-link justify-self-start font-mono text-xs uppercase tracking-wider md:justify-self-end"
          >
            Open shelf →
          </.link>
        </article>
      </div>
    </div>
    """
  end

  attr :contributor, :map, default: nil
  attr :streams, :map, required: true

  def show(assigns) do
    ~H"""
    <div id="contributor-detail-shell" class="archive-wash space-y-10 pb-12">
      <%= if @contributor do %>
        <header class="border-b qi-divider pb-7">
          <.link
            navigate={~p"/contributors"}
            class="qi-action-link font-mono text-xs uppercase tracking-wider"
          >← Contributors</.link>
          <div class="mt-6 grid gap-6 md:grid-cols-[minmax(0,1fr)_16rem] md:items-end">
            <div class="space-y-4">
              <div id="contributor-roles" class="flex flex-wrap gap-2">
                <span
                  :for={role <- @contributor.roles}
                  class="rounded-sm border border-[var(--hiraeth-line-strong)] px-2 py-1 font-mono text-[10px] uppercase tracking-wider text-[var(--hiraeth-muted)]"
                >
                  {role}
                </span>
              </div>
              <h1
                id="contributor-title"
                class="font-serif text-5xl font-light tracking-tight text-[var(--hiraeth-ink)]"
              >
                {@contributor.name}
              </h1>
              <p class="qi-muted max-w-2xl font-serif text-lg italic leading-relaxed">
                Related records appear only when the contributor relationship is sourced in the catalog.
              </p>
            </div>
            <div class="qi-panel-soft p-4">
              <p class="qi-label">Sourced shelf</p>
              <p class="mt-2 font-serif text-3xl font-light text-[var(--hiraeth-ink)]">
                {@contributor.books_count} books
              </p>
            </div>
          </div>
        </header>

        <section id="contributor-books" class="space-y-6">
          <div class="flex items-baseline justify-between border-b qi-divider pb-4">
            <h2 class="font-serif text-2xl font-normal text-[var(--hiraeth-ink)]">
              Related sourced books
            </h2>
            <span class="font-mono text-xs text-[var(--hiraeth-muted)]">{@contributor.books_count} records</span>
          </div>
          <div
            id="contributor-books-stream"
            phx-update="stream"
            class="grid grid-cols-2 gap-6 sm:grid-cols-3 lg:grid-cols-4"
          >
            <CatalogComponents.edition_card
              :for={{dom_id, book} <- @streams.contributor_books}
              dom_id={dom_id}
              edition={book}
              id_prefix="contributor-book"
            />
          </div>
        </section>
      <% else %>
        <CatalogComponents.empty_state
          id="contributor-not-found"
          title="No contributor matches"
          message="No sourced contributor matches that slug. Choose another name from the contributor directory."
          action_label="Back to contributors"
          action_path="/contributors"
        />
      <% end %>
    </div>
    """
  end

  defp title("author"), do: "Authors"
  defp title("translator"), do: "Translators"
  defp title(_role), do: "Contributors"

  defp count_label(1), do: "01 book"

  defp count_label(count) do
    count
    |> Integer.to_string()
    |> String.pad_leading(2, "0")
    |> Kernel.<>(" books")
  end

  defp role_link_class(current, role) do
    base = "rounded-sm border px-3 py-1 transition-colors qi-focus"

    if current == role do
      base <>
        " border-[var(--hiraeth-thread)] bg-[var(--hiraeth-thread)] text-[var(--hiraeth-paper)]"
    else
      base <>
        " border-[var(--hiraeth-line-strong)] text-[var(--hiraeth-muted)] hover:border-[var(--hiraeth-thread)] hover:text-[var(--hiraeth-thread)]"
    end
  end
end
