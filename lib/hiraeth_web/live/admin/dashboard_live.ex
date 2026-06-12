defmodule HiraethWeb.Admin.DashboardLive do
  use HiraethWeb, :live_view

  alias Hiraeth.Catalog.{Edition, Publisher}
  alias Hiraeth.Covers.CoverAssignment
  alias Hiraeth.Imports.{ImportRun, ReviewItem}

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:stats, dashboard_stats(actor))
     |> stream(:import_runs, import_runs(actor), dom_id: &"import-run-#{&1.id}")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} current_scope={%{}}>
      <div id="admin-dashboard-shell" class="space-y-8">
        <div class="border-b border-[#E7E2D8] dark:border-[#2E2A27] pb-5">
          <p class="font-mono text-xs uppercase tracking-wider text-stone-500">
            Catalog Administration
          </p>
          <h1 class="font-serif text-3xl font-medium tracking-tight text-stone-900 dark:text-stone-100 mt-1">
            Cataloger's Desk (Admin dashboard)
          </h1>
          <p class="text-sm text-stone-600 dark:text-stone-400 mt-2">
            Logged in as <span class="font-mono text-stone-900 dark:text-stone-200">{@current_user.email}</span>. Use these tools to manage the editorial archive.
          </p>
        </div>

        <div class="grid grid-cols-1 md:grid-cols-3 gap-6">
          <div class="bg-[#F5F2EB] dark:bg-[#1C1917] p-6 border border-[#E7E2D8] dark:border-[#2E2A27] rounded-sm">
            <span class="font-mono text-xs uppercase tracking-wider text-stone-500">Active Titles</span>
            <div class="mt-2 flex items-baseline gap-2">
              <span class="font-serif text-3xl font-semibold">{@stats.editions}</span>
              <span class="text-xs text-stone-500 font-medium">Ash-backed editions</span>
            </div>
          </div>
          <div class="bg-[#F5F2EB] dark:bg-[#1C1917] p-6 border border-[#E7E2D8] dark:border-[#2E2A27] rounded-sm">
            <span class="font-mono text-xs uppercase tracking-wider text-stone-500">Publishers</span>
            <div class="mt-2 flex items-baseline gap-2">
              <span class="font-serif text-3xl font-semibold">{@stats.publishers}</span>
              <span class="text-xs text-stone-500 font-medium">Catalog records</span>
            </div>
          </div>
          <div class="bg-[#F5F2EB] dark:bg-[#1C1917] p-6 border border-[#E7E2D8] dark:border-[#2E2A27] rounded-sm">
            <span class="font-mono text-xs uppercase tracking-wider text-stone-500">Review queue</span>
            <div class="mt-2 flex items-baseline gap-2">
              <span class="font-serif text-3xl font-semibold">{@stats.pending_reviews}</span>
              <span class="text-xs text-stone-500 font-medium">
                {@stats.hidden_covers} hidden covers
              </span>
            </div>
          </div>
        </div>

        <div id="admin-import-runs" class="space-y-4">
          <div class="flex items-center justify-between border-b border-[#E7E2D8] dark:border-[#2E2A27] pb-2">
            <h2 class="font-serif text-lg font-medium">Recent Import Runs</h2>
            <.link
              navigate={~p"/admin/review"}
              class="font-mono text-xs uppercase tracking-wider text-[#8C2D19] dark:text-[#E05A47] hover:underline font-bold"
            >
              Review Queue &rarr;
            </.link>
          </div>

          <div class="overflow-x-auto">
            <table class="w-full text-left text-sm border-collapse">
              <thead>
                <tr class="border-b border-[#E7E2D8] dark:border-[#2E2A27]">
                  <th class="py-3 font-mono text-xs uppercase text-stone-500 font-semibold">
                    Provider
                  </th>
                  <th class="py-3 font-mono text-xs uppercase text-stone-500 font-semibold">
                    Status
                  </th>
                  <th class="py-3 font-mono text-xs uppercase text-stone-500 font-semibold">
                    Row limit
                  </th>
                  <th class="py-3 font-mono text-xs uppercase text-stone-500 font-semibold">
                    Actions
                  </th>
                </tr>
              </thead>
              <tbody
                id="admin-import-run-rows"
                phx-update="stream"
                class="divide-y divide-[#E7E2D8]/50 dark:divide-[#2E2A27]/50"
              >
                <tr id="admin-import-empty" class="hidden only:table-row">
                  <td colspan="4" class="py-4 text-sm text-stone-600 dark:text-stone-400">
                    No import runs have been created yet. Start with admin imports when that workflow is enabled.
                  </td>
                </tr>
                <tr :for={{dom_id, run} <- @streams.import_runs} id={dom_id}>
                  <td class="py-3 font-medium">{run.provider}</td>
                  <td class="py-3">
                    <span class="inline-flex items-center gap-1.5 rounded-full bg-stone-100 px-2 py-0.5 text-xs font-medium text-stone-700 dark:bg-stone-900 dark:text-stone-300">
                      {run.status}
                    </span>
                  </td>
                  <td class="py-3 font-mono text-stone-600 dark:text-stone-400">{run.row_limit}</td>
                  <td class="py-3">
                    <.link
                      navigate={~p"/admin/review"}
                      class="text-xs font-bold uppercase tracking-wider text-[#8C2D19] hover:underline"
                    >
                      Review items
                    </.link>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp dashboard_stats(actor) do
    %{
      editions: Edition |> Ash.read!(actor: actor) |> length(),
      publishers: Publisher |> Ash.read!(actor: actor) |> length(),
      pending_reviews:
        ReviewItem
        |> Ash.read!(actor: actor)
        |> Enum.count(&(&1.decision == "pending")),
      hidden_covers:
        CoverAssignment
        |> Ash.read!(actor: actor)
        |> Enum.count(&(not &1.visible?))
    }
  end

  defp import_runs(actor) do
    ImportRun
    |> Ash.read!(actor: actor)
    |> Enum.sort_by(&{&1.provider, &1.status, &1.id})
  end
end
