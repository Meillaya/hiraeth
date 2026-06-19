defmodule HiraethWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use HiraethWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :catalog_count, :integer, default: nil, doc: "public catalog count for the masthead"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="qi-header sticky top-0 z-40 transition-colors duration-300">
      <div class="qi-container">
        <div class="grid min-h-[var(--hiraeth-header-height)] grid-cols-[minmax(0,1fr)_auto_minmax(0,1fr)] items-center gap-6">
          <.link
            navigate={~p"/"}
            class="qi-focus flex min-w-0 items-baseline gap-3 justify-self-start"
          >
            <span class="qi-wordmark truncate text-[26px] font-normal">Hiraeth</span>
            <span class="hidden font-sans text-[9.5px] font-semibold uppercase tracking-[0.24em] text-[var(--hiraeth-thread)] sm:inline-block">
              Archive
            </span>
          </.link>

          <nav
            class="hidden items-center gap-[30px] justify-self-center text-[13px] font-medium md:flex"
            aria-label="Primary navigation"
          >
            <.link navigate={~p"/browse"} class="qi-nav-link">Browse</.link>
            <.link navigate={~p"/search"} class="qi-nav-link">Search</.link>
            <.link navigate={~p"/publishers"} class="qi-nav-link">Publishers</.link>
            <.link navigate={~p"/series"} class="qi-nav-link">Series</.link>
          </nav>

          <div class="hidden min-w-0 items-center gap-[30px] justify-self-end sm:flex">
            <nav class="flex min-w-0 items-center gap-[30px]" aria-label="Archive controls">
              <span class="border-l qi-divider pl-[30px] font-mono text-[11px] lowercase text-[var(--hiraeth-label)]">
                <%= if @catalog_count do %>
                  {@catalog_count} vols
                <% else %>
                  Archive
                <% end %>
              </span>
              <div class="flex items-center gap-2">
                <span class="w-8 text-right font-mono text-[9px] uppercase tracking-[0.12em] text-[var(--hiraeth-label)]">
                  <span class="dark:hidden">Light</span>
                  <span class="hidden dark:inline">Dark</span>
                </span>
                <.theme_toggle />
              </div>
            </nav>
          </div>
        </div>
      </div>
    </header>

    <nav
      class="qi-mobile-nav border-b px-4 py-3 md:hidden"
      aria-label="Mobile primary navigation"
    >
      <div class="mx-auto flex max-w-[var(--hiraeth-measure)] items-center gap-4 overflow-x-auto text-sm font-semibold">
        <.link navigate={~p"/browse"} class="qi-nav-link shrink-0">Browse</.link>
        <.link navigate={~p"/search"} class="qi-nav-link shrink-0">Search</.link>
        <.link navigate={~p"/publishers"} class="qi-nav-link shrink-0">Publishers</.link>
        <.link navigate={~p"/series"} class="qi-nav-link shrink-0">Series</.link>
      </div>
    </nav>

    <main class="flex-grow py-12">
      <div class="qi-container">
        {render_slot(@inner_block)}
      </div>
    </main>

    <footer class="qi-footer mt-auto border-t py-8 text-xs">
      <div class="mx-auto flex max-w-[var(--hiraeth-measure)] flex-col items-center justify-between gap-4 px-4 sm:px-6 md:flex-row lg:px-10">
        <p class="font-serif qi-muted">
          Hiraeth &mdash; A quiet editorial archive of independent publishers.
        </p>
        <p class="font-mono qi-label">
          © {DateTime.utc_now().year} Hiraeth Project. All rights reserved.
        </p>
      </div>
    </footer>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <button
      type="button"
      class="qi-focus flex h-[26px] w-12 cursor-pointer items-center rounded-full border border-[var(--hiraeth-line)] bg-[var(--hiraeth-surface)] px-[3px] dark:hidden"
      phx-click={JS.dispatch("phx:set-theme")}
      data-phx-theme="dark"
      aria-label="Switch to dark theme"
      title="Switch to dark theme"
    >
      <span class="block size-5 rounded-full bg-[var(--hiraeth-thread)] shadow-sm transition-transform duration-200"></span>
    </button>
    <button
      type="button"
      class="qi-focus hidden h-[26px] w-12 cursor-pointer items-center rounded-full border border-[var(--hiraeth-line)] bg-[var(--hiraeth-surface)] px-[3px] dark:flex"
      phx-click={JS.dispatch("phx:set-theme")}
      data-phx-theme="light"
      aria-label="Switch to light theme"
      title="Switch to light theme"
    >
      <span class="block size-5 translate-x-[22px] rounded-full bg-[var(--hiraeth-thread)] shadow-sm transition-transform duration-200"></span>
    </button>
    """
  end
end
