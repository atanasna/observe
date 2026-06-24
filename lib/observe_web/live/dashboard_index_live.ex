defmodule ObserveWeb.DashboardIndexLive do
  use ObserveWeb, :live_view

  alias Observe.Store

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, dashboards: Store.list_dashboards(), collapsed_folders: MapSet.new())}
  end

  @impl true
  def handle_event("toggle_folder", %{"path" => path}, socket) do
    {:noreply,
     assign(socket, :collapsed_folders, toggle_path(socket.assigns.collapsed_folders, path))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section id="dashboard-index" class="min-h-[70vh] space-y-8">
        <div class="mocha-shell sharp-corner p-8 md:p-10">
          <div class="absolute right-8 top-8 hidden h-28 w-28 border border-[#f5c2e7]/20 bg-[#f5c2e7]/10 md:block" />
          <p class="mocha-label text-sm font-semibold uppercase tracking-[0.3em]">Observe</p>
          <div class="mt-4 flex flex-col gap-6 lg:flex-row lg:items-end lg:justify-between">
            <div>
              <h1 class="mocha-heading max-w-3xl text-5xl font-semibold tracking-tight md:text-6xl">
                Provisioned dashboards
              </h1>
              <p class="mocha-muted mt-5 max-w-2xl text-lg leading-8">
                YAML-defined dashboards backed by reusable first-class queries and compiled execution plans.
              </p>
            </div>
            <.link
              navigate={~p"/docs"}
              class="mocha-button sharp-corner px-5 py-3 text-sm font-semibold transition"
            >
              Read the docs
            </.link>
          </div>
          <div class="mt-8 grid gap-3 md:grid-cols-3">
            <div class="border border-[#b4befe]/16 bg-[#11111b]/35 p-4">
              <p class="text-xs font-semibold uppercase tracking-[0.2em] text-[#f9e2af]">
                Query graph
              </p>
              <p class="mt-2 text-2xl font-semibold text-[#cdd6f4]">Reusable</p>
            </div>
            <div class="border border-[#b4befe]/16 bg-[#11111b]/35 p-4">
              <p class="text-xs font-semibold uppercase tracking-[0.2em] text-[#a6e3a1]">
                Provisioning
              </p>
              <p class="mt-2 text-2xl font-semibold text-[#cdd6f4]">YAML-first</p>
            </div>
            <div class="border border-[#b4befe]/16 bg-[#11111b]/35 p-4">
              <p class="text-xs font-semibold uppercase tracking-[0.2em] text-[#89dceb]">Runtime</p>
              <p class="mt-2 text-2xl font-semibold text-[#cdd6f4]">Plan-visible</p>
            </div>
          </div>
        </div>

        <div id="dashboard-tree" class="mocha-card sharp-corner p-5">
          <div
            :if={@dashboards == []}
            class="border border-dashed border-[#b4befe]/20 p-8 text-[#bac2de]"
          >
            No dashboards found in <code>config/dashboards</code>.
          </div>

          <div :if={@dashboards != []} class="border border-[#b4befe]/12 bg-[#11111b]/35">
            <div class="grid grid-cols-[1fr_auto_auto] border-b border-[#b4befe]/12 px-4 py-3 text-xs font-semibold uppercase tracking-[0.18em] text-[#89dceb]">
              <span>Provisioning Tree</span>
              <span>Queries</span>
              <span class="ml-6">Panels</span>
            </div>
            <div class="divide-y divide-[#45475a]/50">
              <%= for row <- dashboard_tree_rows(@dashboards, @collapsed_folders) do %>
                <div
                  :if={row.kind == :folder}
                  id={"dashboard-folder-#{Enum.join(row.path, "-")}"}
                  class="tree-clickable grid grid-cols-[1fr_auto_auto] items-center px-4 py-3 text-sm transition"
                >
                  <button
                    type="button"
                    phx-click="toggle_folder"
                    phx-value-path={path_key(row.path)}
                    class="flex items-center gap-3 text-left"
                    style={"padding-left: #{row.depth * 1.25}rem"}
                  >
                    <span class="tree-arrow w-5 text-xl leading-none text-[#f9e2af]">
                      {if row.collapsed, do: "▸", else: "▾"}
                    </span>
                    <span class="font-semibold text-[#cdd6f4]">{row.name}</span>
                  </button>
                  <span class="text-right text-[#6c7086]">-</span>
                  <span class="ml-6 text-right text-[#6c7086]">-</span>
                </div>

                <a
                  :if={row.kind == :dashboard}
                  id={"dashboard-node-#{get_in(row.dashboard, ["metadata", "name"])}"}
                  href={~p"/dashboards/#{get_in(row.dashboard, ["metadata", "name"])}"}
                  phx-click={
                    JS.navigate(~p"/dashboards/#{get_in(row.dashboard, ["metadata", "name"])}")
                  }
                  class="tree-clickable group grid grid-cols-[1fr_auto_auto] items-center px-4 py-3 text-sm transition"
                >
                  <div
                    class="flex min-w-0 items-center gap-3"
                    style={"padding-left: #{row.depth * 1.25}rem"}
                  >
                    <span class="tree-arrow text-[#89dceb]">└</span>
                    <div class="min-w-0">
                      <p class="truncate font-semibold text-[#cdd6f4] group-hover:text-[#f5c2e7]">
                        {get_in(row.dashboard, ["metadata", "title"]) ||
                          get_in(row.dashboard, ["metadata", "name"])}
                      </p>
                      <p class="mt-1 truncate text-xs text-[#9399b2]">
                        {get_in(row.dashboard, ["metadata", "name"])} · {get_in(row.dashboard, [
                          "_meta",
                          "folder"
                        ]) || "root"}
                      </p>
                    </div>
                  </div>
                  <span class="text-right font-semibold text-[#a6e3a1]">
                    {map_size(Map.get(row.dashboard, "queries", %{}))}
                  </span>
                  <span class="ml-6 text-right font-semibold text-[#89dceb]">
                    {length(Map.get(row.dashboard, "panels", []))}
                  </span>
                </a>
              <% end %>
            </div>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp dashboard_tree_rows(dashboards, collapsed_folders) do
    folders = dashboards |> Enum.map(&folder_parts/1) |> Enum.uniq()

    []
    |> build_dashboard_rows(folders, dashboards)
    |> visible_rows(collapsed_folders, :dashboard)
    |> Enum.map(&put_collapsed(&1, collapsed_folders))
  end

  defp build_dashboard_rows(prefix, folders, dashboards) do
    child_folders =
      folders
      |> Enum.filter(&(Enum.take(&1, length(prefix)) == prefix and length(&1) > length(prefix)))
      |> Enum.map(&Enum.at(&1, length(prefix)))
      |> Enum.uniq()
      |> Enum.sort()

    folder_rows =
      Enum.flat_map(child_folders, fn name ->
        path = prefix ++ [name]

        [
          %{kind: :folder, name: name, path: path, depth: length(prefix)}
          | build_dashboard_rows(path, folders, dashboards)
        ]
      end)

    leaf_rows =
      dashboards
      |> Enum.filter(&(folder_parts(&1) == prefix))
      |> Enum.sort_by(&(get_in(&1, ["metadata", "title"]) || get_in(&1, ["metadata", "name"])))
      |> Enum.map(
        &%{kind: :dashboard, dashboard: &1, path: folder_parts(&1), depth: length(prefix)}
      )

    folder_rows ++ leaf_rows
  end

  defp folder_parts(item) do
    item
    |> get_in(["_meta", "folder"])
    |> case do
      nil -> ["root"]
      "root" -> ["root"]
      folder -> String.split(folder, "/", trim: true)
    end
  end

  defp visible_rows(rows, collapsed_folders, leaf_kind) do
    Enum.reject(rows, &hidden_by_collapsed_folder?(&1, collapsed_folders, leaf_kind))
  end

  defp hidden_by_collapsed_folder?(%{kind: :folder, path: path}, collapsed_folders, _leaf_kind) do
    path
    |> parent_paths()
    |> Enum.any?(&MapSet.member?(collapsed_folders, path_key(&1)))
  end

  defp hidden_by_collapsed_folder?(%{kind: leaf_kind, path: path}, collapsed_folders, leaf_kind) do
    path
    |> prefixes()
    |> Enum.any?(&MapSet.member?(collapsed_folders, path_key(&1)))
  end

  defp put_collapsed(%{kind: :folder, path: path} = row, collapsed_folders) do
    Map.put(row, :collapsed, MapSet.member?(collapsed_folders, path_key(path)))
  end

  defp put_collapsed(row, _collapsed_folders), do: row

  defp toggle_path(collapsed_folders, path) do
    if MapSet.member?(collapsed_folders, path) do
      MapSet.delete(collapsed_folders, path)
    else
      MapSet.put(collapsed_folders, path)
    end
  end

  defp parent_paths(path) do
    path
    |> prefixes()
    |> Enum.drop(-1)
  end

  defp prefixes(path), do: Enum.map(1..length(path)//1, &Enum.take(path, &1))
  defp path_key(path), do: Enum.join(path, "/")
end
