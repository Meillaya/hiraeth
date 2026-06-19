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
    publishers =
      PublicCatalog.publishers()
      |> Enum.with_index(1)
      |> Enum.map(fn {publisher, index} ->
        Map.put(publisher, :row_number, index)
      end)

    {:noreply,
     socket
     |> assign(:page_title, "Curated Publishers")
     |> assign(:publisher_count, length(publishers))
     |> assign(:publisher_editions_count, Enum.sum(Enum.map(publishers, & &1.editions_count)))
     |> stream(:publishers, publishers,
       reset: true,
       dom_id: &"publisher-#{&1.slug}"
     )}
  end

  @impl true
  def render(%{live_action: :show} = assigns), do: render_show(assigns)
  def render(assigns), do: render_index(assigns)

  defp render_index(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={%{}}
      catalog_count={@publisher_editions_count}
    >
      <div id="publishers-shell" class="archive-wash space-y-10">
        <header class="flex flex-col gap-5 border-b border-[var(--hiraeth-line)] pb-5 sm:flex-row sm:items-end sm:justify-between">
          <div>
            <p class="font-sans text-[11px] font-semibold uppercase tracking-[0.26em] text-[var(--hiraeth-thread)]">
              Independent presses
            </p>
            <h1 class="mt-2 font-serif text-4xl font-light tracking-tight text-[var(--hiraeth-ink)] sm:text-5xl">
              Publishers
            </h1>
          </div>
          <p class="font-mono text-[11px] text-[var(--hiraeth-muted)]">
            {@publisher_count} houses · {@publisher_editions_count} sourced books
          </p>
        </header>

        <div id="publishers-grid" phx-update="stream" class="divide-y divide-[var(--hiraeth-line)]">
          <article
            :for={{dom_id, pub} <- @streams.publishers}
            id={dom_id}
            class="group grid gap-6 py-8 transition-colors duration-200 hover:bg-[var(--hiraeth-warm)]/70 sm:grid-cols-[3.75rem_minmax(0,1fr)_6.875rem]"
          >
            <div class="font-mono text-[13px] text-[var(--hiraeth-label)]">
              {pub.row_number |> Integer.to_string() |> String.pad_leading(2, "0")}
            </div>
            <div class="min-w-0 space-y-3">
              <h2 class="font-serif text-3xl font-light leading-none text-[var(--hiraeth-ink)] sm:text-[34px]">
                <.link
                  navigate={~p"/publishers/#{pub.slug}"}
                  class="transition-colors duration-200 group-hover:text-[var(--hiraeth-thread)]"
                >
                  {pub.name}
                </.link>
              </h2>
              <p
                :if={pub[:description]}
                class="max-w-2xl font-serif text-base italic leading-relaxed text-[var(--hiraeth-muted)]"
              >
                {pub.description}
              </p>
              <p class="font-mono text-[10px] uppercase tracking-[0.1em] text-[var(--hiraeth-label)]">
                {pub.editions_count} sourced books · local catalog metadata
              </p>
            </div>
            <div class="flex items-center justify-start sm:justify-end">
              <.link
                navigate={~p"/publishers/#{pub.slug}"}
                class="qi-focus block w-[84px]"
                aria-label={"Open #{pub.name}"}
              >
                <img
                  :if={sample_cover_src(pub.cover_sample)}
                  src={sample_cover_src(pub.cover_sample)}
                  alt={"Cover thumbnail for #{pub.cover_sample.title}"}
                  loading="lazy"
                  decoding="async"
                  width="84"
                  height="126"
                  class="aspect-[2/3] w-full border border-[var(--hiraeth-line)] object-cover transition-colors group-hover:border-[var(--hiraeth-thread)]"
                />
                <div
                  :if={!sample_cover_src(pub.cover_sample)}
                  class="fallback-cover-grain relative flex aspect-[2/3] w-full items-center justify-center overflow-hidden border border-[var(--hiraeth-line)] p-2 text-center font-serif text-[11px] leading-tight text-[var(--hiraeth-muted)]"
                  aria-label="Typographic cover fallback; no cover asset is available."
                >
                  {pub.name}
                </div>
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
    <Layouts.app flash={@flash} current_scope={%{}}>
      <div id="publisher-detail-shell" class="archive-wash space-y-10">
        <%= if @publisher do %>
          <header id="publisher-masthead" class="border-b border-[var(--hiraeth-line)] pb-7">
            <.link
              navigate={~p"/publishers"}
              class="font-mono text-[11px] uppercase tracking-[0.16em] text-[var(--hiraeth-muted)] transition-colors hover:text-[var(--hiraeth-thread)]"
            >← Publishers</.link>
            <div class="mt-7 grid gap-8 lg:grid-cols-[minmax(0,1fr)_17rem] lg:items-end">
              <div class="space-y-4">
                <p class="font-sans text-[11px] font-semibold uppercase tracking-[0.26em] text-[var(--hiraeth-thread)]">
                  Publisher dossier
                </p>
                <h1
                  id="publisher-title"
                  class="max-w-4xl font-serif text-5xl font-light leading-none tracking-tight text-[var(--hiraeth-ink)] md:text-6xl"
                >
                  {@publisher.name}
                </h1>
                <p
                  :if={@publisher[:description]}
                  class="max-w-3xl font-serif text-lg italic leading-relaxed text-[var(--hiraeth-muted)]"
                >
                  {@publisher.description}
                </p>
                <p class="max-w-2xl font-sans text-sm leading-6 text-[var(--hiraeth-muted)]">
                  This page summarizes only sourced local catalog metadata currently attached to the press.
                </p>
              </div>
              <.link
                id="publisher-browse-cta"
                navigate={~p"/browse?publisher=#{@publisher.slug}"}
                class="inline-flex items-center justify-center border border-[var(--hiraeth-thread)] bg-[var(--hiraeth-ink)] px-5 py-3 text-center font-sans text-xs font-semibold uppercase tracking-[0.14em] text-[var(--hiraeth-paper)] transition duration-200 hover:-translate-y-0.5 hover:bg-[var(--hiraeth-thread)] focus:outline-none focus:ring-2 focus:ring-[var(--hiraeth-thread)] focus:ring-offset-2 focus:ring-offset-[var(--hiraeth-paper)]"
              >
                Browse this press
              </.link>
            </div>
          </header>

          <section
            id="publisher-context"
            class="grid gap-0 overflow-hidden rounded-sm border border-[var(--hiraeth-line)] bg-[var(--hiraeth-wash)]/70 sm:grid-cols-3"
          >
            <.stat_block
              label="Sourced shelf"
              value={plural_count(@publisher.editions_count, "book")}
            />
            <.stat_block label="Formats" value={group_summary(@publisher.groupings.formats)} />
            <.stat_block label="Languages" value={group_summary(@publisher.groupings.languages)} />
          </section>

          <section id="publisher-groups" class="grid gap-6 lg:grid-cols-2">
            <.group_panel
              id="publisher-formats"
              title="Format shelf"
              note="Formats present across this publisher's sourced books."
              groups={@publisher.groupings.formats}
              empty="No format metadata is sourced yet."
            />
            <.group_panel
              id="publisher-languages"
              title="Language register"
              note="Edition and original-language values appear only when source records provide them."
              groups={@publisher.groupings.languages}
              secondary_groups={@publisher.groupings.original_languages}
              secondary_title="Original languages"
              empty="No language metadata is sourced yet."
            />
            <.group_panel
              id="publisher-series"
              title="Collections and series"
              note="Series groupings are bounded to currently attached sourced books."
              groups={@publisher.groupings.series}
              empty="No series or collection memberships are sourced yet."
            />
            <.group_panel
              id="publisher-translations"
              title="Translation signals"
              note="Translation groupings are inferred only from sourced languages and contributor roles."
              groups={@publisher.groupings.translations}
              secondary_groups={@publisher.groupings.contributor_roles}
              secondary_title="Contributor roles"
              empty="No translation metadata is sourced yet."
            />
          </section>

          <section id="publisher-editions" class="space-y-6">
            <div class="flex flex-col gap-2 border-b border-[var(--hiraeth-line)] pb-4 sm:flex-row sm:items-end sm:justify-between">
              <div>
                <p class="font-sans text-[10px] font-semibold uppercase tracking-[0.22em] text-[var(--hiraeth-thread)]">
                  Current books
                </p>
                <h2 class="mt-1 font-serif text-3xl font-light text-[var(--hiraeth-ink)]">
                  Cataloged books
                </h2>
              </div>
              <p class="font-mono text-[11px] text-[var(--hiraeth-muted)]">
                Streamed from the public catalog projection
              </p>
            </div>
            <%= if @publisher.editions_count == 0 do %>
              <CatalogComponents.empty_state
                id="publisher-no-editions"
                title="No books are attached"
                message="No books are attached to this publisher yet. The publisher record is public, but the shelf stays empty until sourced books are imported or curated."
                action_label="Back to publishers"
                action_path="/publishers"
              />
            <% else %>
              <div
                id="publisher-editions-stream"
                phx-update="stream"
                class="grid grid-cols-2 gap-6 sm:grid-cols-3 md:grid-cols-4"
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

  attr :label, :string, required: true
  attr :value, :string, required: true

  defp stat_block(assigns) do
    ~H"""
    <div class="border-b border-[var(--hiraeth-line)] p-5 sm:border-b-0 sm:border-r last:border-r-0">
      <p class="font-mono text-[10px] uppercase tracking-[0.18em] text-[var(--hiraeth-label)]">
        {@label}
      </p>
      <p class="mt-2 font-serif text-xl text-[var(--hiraeth-ink)]">{@value}</p>
    </div>
    """
  end

  defp sample_cover_src(nil), do: nil

  defp sample_cover_src(edition) do
    case edition[:cover] do
      nil ->
        nil

      cover ->
        local_cover_url(cover[:thumbnail_url]) || local_cover_url(cover[:public_url])
    end
  end

  defp local_cover_url(url) when is_binary(url) do
    if String.starts_with?(url, "/covers/cache/"), do: url
  end

  defp local_cover_url(_url), do: nil

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :note, :string, required: true
  attr :groups, :list, required: true
  attr :empty, :string, required: true
  attr :secondary_groups, :list, default: []
  attr :secondary_title, :string, default: nil

  defp group_panel(assigns) do
    ~H"""
    <article
      id={@id}
      class="hiraeth-surface space-y-5 rounded-sm border border-[var(--hiraeth-line)] p-6"
    >
      <div>
        <h3 class="font-serif text-2xl font-light text-[var(--hiraeth-ink)]">{@title}</h3>
        <p class="mt-2 font-sans text-sm leading-6 text-[var(--hiraeth-muted)]">{@note}</p>
      </div>

      <%= if @groups == [] do %>
        <p class="border border-dashed border-[var(--hiraeth-line)] bg-[var(--hiraeth-warm)] px-4 py-3 font-serif text-sm italic text-[var(--hiraeth-muted)]">
          {@empty}
        </p>
      <% else %>
        <ul class="space-y-2">
          <li
            :for={group <- @groups}
            class="flex items-baseline justify-between gap-4 border-t border-[var(--hiraeth-line)] pt-2"
          >
            <span class="font-serif text-base text-[var(--hiraeth-ink)]">{group.label}</span>
            <span class="font-mono text-[11px] text-[var(--hiraeth-label)]">
              {plural_count(group.count, "record")}
            </span>
          </li>
        </ul>
      <% end %>

      <div :if={@secondary_groups != []} class="space-y-2 border-t border-[var(--hiraeth-line)] pt-4">
        <p class="font-mono text-[10px] uppercase tracking-[0.18em] text-[var(--hiraeth-label)]">
          {@secondary_title}
        </p>
        <div class="flex flex-wrap gap-2">
          <span
            :for={group <- @secondary_groups}
            class="border border-[var(--hiraeth-line)] bg-[var(--hiraeth-warm)] px-2.5 py-1 font-mono text-[10px] uppercase tracking-[0.12em] text-[var(--hiraeth-muted)]"
          >
            {group.label} · {group.count}
          </span>
        </div>
      </div>
    </article>
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

  defp group_summary([]), do: "Not sourced"

  defp group_summary(groups) do
    groups
    |> Enum.take(3)
    |> Enum.map(& &1.label)
    |> Enum.join(" · ")
  end

  defp plural_count(1, singular), do: "1 #{singular}"
  defp plural_count(count, singular), do: "#{count} #{singular}s"
end
