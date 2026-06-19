defmodule HiraethWeb.SeriesLive do
  use HiraethWeb, :live_view

  alias HiraethWeb.PublicCatalog
  alias HiraethWeb.SeriesLive.Components

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Series & Imprints")}
  end

  @impl true
  def handle_params(%{"slug" => slug}, _uri, socket) do
    {:noreply,
     socket
     |> assign(:page_title, "Series")
     |> assign_series(PublicCatalog.series_by_slug(slug))}
  end

  def handle_params(_params, _uri, socket) do
    series = PublicCatalog.series()

    {:noreply,
     socket
     |> assign(:page_title, "Series & Imprints")
     |> assign(:series_empty?, series == [])
     |> stream(:series_list, series, reset: true, dom_id: &"series-#{&1.slug}")}
  end

  @impl true
  def render(%{live_action: :show} = assigns), do: render_show(assigns)
  def render(assigns), do: render_index(assigns)

  defp render_index(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={%{}}>
      <Components.index series_empty?={@series_empty?} streams={@streams} />
    </Layouts.app>
    """
  end

  defp render_show(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={%{}}>
      <Components.show series={@series} streams={@streams} />
    </Layouts.app>
    """
  end

  defp assign_series(socket, nil) do
    socket
    |> assign(:series, nil)
    |> stream(:series_editions, [], reset: true)
  end

  defp assign_series(socket, series) do
    socket
    |> assign(:series, series)
    |> stream(:series_editions, series.editions, reset: true)
  end
end
