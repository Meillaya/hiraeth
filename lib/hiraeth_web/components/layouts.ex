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

  attr :current_user, :map, default: nil, doc: "the currently authenticated user"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="qi-header sticky top-0 z-40 transition-colors duration-300">
      <div class="qi-container">
        <div class="flex min-h-[var(--hiraeth-header-height)] items-center justify-between gap-6">
          <div class="flex min-w-0 items-center gap-8">
            <.link navigate={~p"/"} class="qi-focus flex min-w-0 items-center gap-2">
              <span class="qi-wordmark truncate text-2xl font-semibold">Hiraeth</span>
              <span class="qi-kicker hidden border px-1.5 py-0.5 sm:inline-block">Archive</span>
            </.link>
            <nav
              class="hidden items-center gap-6 text-sm font-semibold md:flex"
              aria-label="Primary navigation"
            >
              <.link navigate={~p"/browse"} class="qi-nav-link">Browse</.link>
              <.link navigate={~p"/search"} class="qi-nav-link">Search</.link>
              <.link navigate={~p"/publishers"} class="qi-nav-link">Publishers</.link>
              <.link navigate={~p"/series"} class="qi-nav-link">Series</.link>
            </nav>
          </div>

          <div class="hidden min-w-0 items-center gap-4 sm:flex">
            <nav class="flex min-w-0 items-center gap-4" aria-label="Account navigation">
              <%= if @current_user do %>
                <div class="hidden min-w-0 items-center gap-2 text-xs xl:flex">
                  <span class="qi-muted max-w-44 truncate font-mono" title={@current_user.email}>
                    {@current_user.email}
                  </span>
                  <%= if @current_user.admin? do %>
                    <span class="qi-kicker bg-[var(--hiraeth-thread-soft)] px-1.5 py-0.5 text-[var(--hiraeth-thread)]">
                      Admin
                    </span>
                  <% end %>
                </div>
                <.link
                  navigate={~p"/admin"}
                  class="qi-nav-link whitespace-nowrap text-sm font-semibold"
                >
                  Dashboard
                </.link>
                <.link
                  href={~p"/sign-out"}
                  class="qi-action-link whitespace-nowrap text-sm font-semibold"
                  method="delete"
                >
                  Sign out
                </.link>
              <% else %>
                <.link navigate={~p"/sign-in"} class="qi-nav-link text-sm font-semibold">
                  Sign in
                </.link>
              <% end %>
              <div class="border-l qi-divider pl-4">
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
        <%= if @current_user do %>
          <.link navigate={~p"/admin"} class="qi-nav-link shrink-0">Dashboard</.link>
          <.link
            href={~p"/sign-out"}
            class="qi-action-link shrink-0"
            method="delete"
          >
            Sign out
          </.link>
        <% else %>
          <.link navigate={~p"/sign-in"} class="qi-nav-link shrink-0">Sign in</.link>
        <% end %>
      </div>
    </nav>

    <main class="flex-grow px-4 py-12 sm:px-6 lg:px-8">
      <div class="mx-auto max-w-[var(--hiraeth-measure)]">
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
    <div class="qi-panel-soft relative flex w-24 flex-row items-center p-0.5">
      <div class="absolute left-0.5 top-0.5 h-[calc(100%-0.25rem)] w-1/3 rounded-[var(--hiraeth-radius)] border border-[var(--hiraeth-line)] bg-[var(--hiraeth-paper)] shadow-sm transition-[left] [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-[calc(66.666%-0.125rem)] [[data-theme-source=system]_&]:!left-0.5" />

      <button
        class="qi-focus qi-muted relative z-10 flex w-1/3 cursor-pointer justify-center rounded-[var(--hiraeth-radius)] p-2 transition hover:text-[var(--hiraeth-ink)]"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        aria-label="Use system theme"
        title="Use system theme"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="qi-focus qi-muted relative z-10 flex w-1/3 cursor-pointer justify-center rounded-[var(--hiraeth-radius)] p-2 transition hover:text-[var(--hiraeth-ink)]"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        aria-label="Use light theme"
        title="Use light theme"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="qi-focus qi-muted relative z-10 flex w-1/3 cursor-pointer justify-center rounded-[var(--hiraeth-radius)] p-2 transition hover:text-[var(--hiraeth-ink)]"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        aria-label="Use dark theme"
        title="Use dark theme"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
