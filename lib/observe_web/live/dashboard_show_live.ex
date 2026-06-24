defmodule ObserveWeb.DashboardShowLive do
  use ObserveWeb, :live_view

  alias Observe.Executor
  alias Observe.PanelCompatibility
  alias Observe.Store
  alias Observe.TimeRange
  alias Observe.Variables

  @impl true
  def mount(%{"name" => name} = params, _session, socket) do
    case Store.get_dashboard(name) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Dashboard #{name} was not found")
         |> push_navigate(to: ~p"/dashboards")}

      dashboard ->
        datasources = Store.datasources()

        variable_values =
          Variables.merge(Map.get(dashboard, "variables", %{}), params, datasources)

        time_range = TimeRange.range(TimeRange.default())
        datetime_values = TimeRange.datetime_local(time_range)

        {:ok,
         socket
         |> assign(:dashboard, dashboard)
         |> assign(:datasources, datasources)
         |> assign(:variable_values, variable_values)
         |> assign(:start_time, datetime_values.start)
         |> assign(:end_time, datetime_values.end)
         |> assign(:refresh_interval, "off")
         |> assign(:refresh_timer, nil)
         |> assign(:run_ref, nil)
         |> assign(:loading?, false)
         |> assign(:plan, nil)
         |> assign(:datasets, %{})
         |> assign(:error, nil)
         |> start_dashboard_run(variable_values)}
    end
  end

  @impl true
  def handle_event("variables_changed", %{"variables" => params}, socket) do
    variable_values =
      Variables.merge(
        Map.get(socket.assigns.dashboard, "variables", %{}),
        params,
        socket.assigns.datasources
      )

    {:noreply, start_dashboard_run(socket, variable_values)}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, start_dashboard_run(socket, socket.assigns.variable_values)}
  end

  def handle_event("controls_changed", %{"controls" => controls}, socket) do
    start_time = valid_datetime(controls, "start_time", socket.assigns.start_time)
    end_time = valid_datetime(controls, "end_time", socket.assigns.end_time)

    socket =
      socket
      |> assign(:start_time, start_time)
      |> assign(:end_time, end_time)
      |> assign(
        :refresh_interval,
        Map.get(controls, "refresh_interval", socket.assigns.refresh_interval)
      )
      |> reset_refresh_timer()
      |> start_dashboard_run(socket.assigns.variable_values)

    {:noreply, socket}
  end

  @impl true
  def handle_info(:poll_dashboard, socket) do
    socket =
      socket
      |> start_dashboard_run(socket.assigns.variable_values)
      |> schedule_refresh_timer()

    {:noreply, socket}
  end

  def handle_info({ref, result}, %{assigns: %{run_ref: ref}} = socket) do
    Process.demonitor(ref, [:flush])

    socket =
      case result do
        {:ok, result} ->
          socket
          |> assign(:plan, result.plan)
          |> assign(:datasets, result.datasets)
          |> assign(:error, nil)

        {:error, reason} ->
          socket
          |> assign(:plan, nil)
          |> assign(:datasets, %{})
          |> assign(:error, reason)
      end

    {:noreply, socket |> assign(:loading?, false) |> assign(:run_ref, nil)}
  end

  def handle_info({ref, _result}, socket) when is_reference(ref), do: {:noreply, socket}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{assigns: %{run_ref: ref}} = socket) do
    {:noreply,
     socket
     |> assign(:loading?, false)
     |> assign(:run_ref, nil)
     |> assign(:error, "dashboard run failed: #{inspect(reason)}")}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, socket), do: {:noreply, socket}

  defp start_dashboard_run(socket, variable_values) do
    opts = %{
      time_range: TimeRange.custom!(socket.assigns.start_time, socket.assigns.end_time)
    }

    task =
      start_query_task(fn -> Executor.run(socket.assigns.dashboard, variable_values, opts) end)

    socket
    |> assign(:variable_values, variable_values)
    |> assign(:loading?, true)
    |> assign(:run_ref, task.ref)
    |> assign(:error, nil)
  end

  defp start_query_task(fun) do
    ensure_query_task_supervisor!()
    Task.Supervisor.async_nolink(Observe.QueryTaskSupervisor, fun)
  end

  defp ensure_query_task_supervisor! do
    case Process.whereis(Observe.QueryTaskSupervisor) do
      nil ->
        case Task.Supervisor.start_link(name: Observe.QueryTaskSupervisor) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      _pid ->
        :ok
    end
  end

  defp reset_refresh_timer(socket) do
    if socket.assigns.refresh_timer do
      Process.cancel_timer(socket.assigns.refresh_timer)
    end

    socket
    |> assign(:refresh_timer, nil)
    |> schedule_refresh_timer()
  end

  defp schedule_refresh_timer(socket) do
    case refresh_ms(socket.assigns.refresh_interval) do
      nil ->
        socket

      ms ->
        assign(socket, :refresh_timer, Process.send_after(self(), :poll_dashboard, ms))
    end
  end

  defp refresh_ms("10s"), do: 10_000
  defp refresh_ms("30s"), do: 30_000
  defp refresh_ms("1m"), do: 60_000
  defp refresh_ms("5m"), do: 300_000
  defp refresh_ms(_interval), do: nil

  defp refresh_options do
    [{"Off", "off"}, {"10s", "10s"}, {"30s", "30s"}, {"1m", "1m"}, {"5m", "5m"}]
  end

  defp valid_datetime(controls, key, current_value) do
    value = Map.get(controls, key, current_value)

    if TimeRange.valid_datetime_local?(value), do: value, else: current_value
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section id="dashboard-show" class="space-y-3">
        <div class="mocha-shell sharp-corner p-3 md:p-4">
          <div class="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
            <div>
              <.link
                navigate={~p"/dashboards"}
                class="text-xs font-semibold text-[#89dceb] transition hover:text-[#f5c2e7]"
              >
                Back to dashboards
              </.link>
              <h1 class="mocha-heading mt-1 text-2xl font-semibold tracking-tight md:text-3xl">
                {get_in(@dashboard, ["metadata", "title"]) || get_in(@dashboard, ["metadata", "name"])}
              </h1>
              <p class="mocha-muted mt-1 text-xs">
                {map_size(Map.get(@dashboard, "queries", %{}))} query nodes · {length(
                  Map.get(@dashboard, "panels", [])
                )} panels
              </p>
            </div>
            <div class="flex flex-wrap items-end gap-2">
              <.form
                for={
                  to_form(%{
                    "controls" => %{
                      "start_time" => @start_time,
                      "end_time" => @end_time,
                      "refresh_interval" => @refresh_interval
                    }
                  })
                }
                id="dashboard-controls"
                phx-change="controls_changed"
                class="flex flex-wrap gap-2"
              >
                <div>
                  <label class="mb-1 block text-[0.65rem] font-semibold uppercase tracking-[0.18em] text-[#89dceb]">
                    Start
                  </label>
                  <input
                    id="dashboard-start-time"
                    type="datetime-local"
                    name="controls[start_time]"
                    value={@start_time}
                    class="border border-[#b4befe]/15 bg-[#11111b]/55 px-2 py-1.5 text-xs font-semibold text-[#cdd6f4] outline-none transition focus:border-[#cba6f7]/70 focus:bg-[#181825]"
                  />
                </div>
                <div>
                  <label class="mb-1 block text-[0.65rem] font-semibold uppercase tracking-[0.18em] text-[#89dceb]">
                    End
                  </label>
                  <input
                    id="dashboard-end-time"
                    type="datetime-local"
                    name="controls[end_time]"
                    value={@end_time}
                    class="border border-[#b4befe]/15 bg-[#11111b]/55 px-2 py-1.5 text-xs font-semibold text-[#cdd6f4] outline-none transition focus:border-[#cba6f7]/70 focus:bg-[#181825]"
                  />
                </div>
                <div>
                  <label class="mb-1 block text-[0.65rem] font-semibold uppercase tracking-[0.18em] text-[#89dceb]">
                    Refresh
                  </label>
                  <select
                    id="dashboard-refresh-interval"
                    name="controls[refresh_interval]"
                    class="border border-[#b4befe]/15 bg-[#11111b]/55 px-2 py-1.5 text-xs font-semibold text-[#cdd6f4] outline-none transition focus:border-[#cba6f7]/70 focus:bg-[#181825]"
                  >
                    <option
                      :for={{label, value} <- refresh_options()}
                      value={value}
                      selected={@refresh_interval == value}
                    >
                      {label}
                    </option>
                  </select>
                </div>
              </.form>
              <button
                id="refresh-dashboard"
                phx-click="refresh"
                class="mocha-button sharp-corner flex items-center gap-2 px-3 py-2 text-xs font-semibold transition"
              >
                <span
                  :if={@loading?}
                  class="inline-block size-3 animate-spin rounded-full border-2 border-[#11111b]/35 border-t-[#11111b]"
                />
                {if @loading?, do: "Loading", else: "Run"}
              </button>
            </div>
          </div>

          <.form
            :if={map_size(Map.get(@dashboard, "variables", %{})) > 0}
            for={to_form(%{"variables" => @variable_values})}
            id="dashboard-variables"
            phx-change="variables_changed"
            class="mt-3 grid gap-2 md:grid-cols-4 xl:grid-cols-6"
          >
            <div :for={{name, spec} <- Map.get(@dashboard, "variables", %{})}>
              <label
                for={"variables_#{name}"}
                class="mb-1 block text-[0.65rem] font-semibold uppercase tracking-[0.18em] text-[#89dceb]"
              >
                {name}
              </label>
              <select
                id={"variables_#{name}"}
                name={"variables[#{name}]"}
                class="w-full border border-[#b4befe]/15 bg-[#11111b]/55 px-2 py-1.5 text-xs font-semibold text-[#cdd6f4] outline-none transition focus:border-[#cba6f7]/70 focus:bg-[#181825]"
              >
                <option
                  :for={{label, value} <- Variables.select_options(spec, @datasources)}
                  value={value}
                  selected={@variable_values[name] == value}
                >
                  {label}
                </option>
              </select>
            </div>
          </.form>
        </div>

        <div
          :if={@error}
          id="dashboard-error"
          class="border border-[#f38ba8]/30 bg-[#f38ba8]/10 p-3 text-xs font-semibold text-[#f38ba8]"
        >
          {@error}
        </div>

        <div
          :if={@plan}
          id="execution-plan"
          class="mocha-panel grid gap-3 p-3 lg:grid-cols-2"
        >
          <div>
            <h2 class="text-xs font-semibold uppercase tracking-[0.18em] text-[#f9e2af]">
              Datasources
            </h2>
            <div class="mt-2 flex flex-wrap gap-1.5">
              <span
                :for={{alias_name, datasource} <- @plan.datasource_aliases}
                class="mocha-chip px-2 py-0.5 text-[0.68rem] font-semibold"
              >
                {alias_name} → {datasource.ref}
              </span>
            </div>
          </div>
          <div>
            <h2 class="text-xs font-semibold uppercase tracking-[0.18em] text-[#a6e3a1]">
              Execution order
            </h2>
            <div class="mt-2 flex max-h-12 flex-wrap gap-1.5 overflow-hidden">
              <span
                :for={{query, index} <- Enum.with_index(@plan.query_order, 1)}
                class="border border-[#89dceb]/20 bg-[#89dceb]/10 px-2 py-0.5 text-[0.68rem] font-semibold text-[#89dceb]"
              >
                {index}. {query}
              </span>
            </div>
          </div>
        </div>

        <div id="panel-grid" class="grid gap-3 xl:grid-cols-2 2xl:grid-cols-3">
          <article
            :for={panel <- Map.get(@dashboard, "panels", [])}
            id={"panel-#{panel["id"]}"}
            class={[
              "mocha-card sharp-corner p-3 transition duration-300",
              panel["type"] == "row" && "xl:col-span-2 2xl:col-span-3"
            ]}
          >
            <div class="mb-2 flex items-start justify-between gap-3">
              <div>
                <h2 class="text-sm font-semibold text-[#cdd6f4]">{panel["title"]}</h2>
                <p class="mt-0.5 text-[0.65rem] font-semibold uppercase tracking-[0.16em] text-[#9399b2]">
                  {panel["type"]}{panel["dataset"] && " · #{panel["dataset"]}"}
                </p>
              </div>
              <span :if={panel["dataset"]} class="mocha-chip px-2 py-0.5 text-[0.68rem] font-semibold">
                {length(Map.get(@datasets, panel["dataset"], []))} rows
              </span>
            </div>

            <%= if panel_loading?(panel, @datasets, @loading?) do %>
              <div class="flex min-h-28 items-center justify-center gap-3 border border-[#89dceb]/20 bg-[#89dceb]/10 p-4 text-xs font-semibold uppercase tracking-[0.16em] text-[#89dceb]">
                <span class="inline-block size-4 animate-spin rounded-full border-2 border-[#89dceb]/25 border-t-[#89dceb]" />
                Loading dataset
              </div>
            <% else %>
              <%= if error = panel_error(panel, @datasets) do %>
                <div class="border border-[#f38ba8]/30 bg-[#f38ba8]/10 p-3 text-xs font-semibold leading-5 text-[#f38ba8]">
                  {error}
                </div>
              <% else %>
                <%= case panel["type"] do %>
                  <% "row" -> %>
                    <div class="border-l-2 border-[#cba6f7] bg-[#11111b]/40 px-3 py-1.5 text-xs font-semibold uppercase tracking-[0.22em] text-[#f5c2e7]">
                      {panel["title"]}
                    </div>
                  <% "stat" -> %>
                    <div class="sharp-corner bg-gradient-to-br from-[#cba6f7] via-[#89b4fa] to-[#94e2d5] p-4 text-[#11111b]">
                      <p class="text-xs font-semibold uppercase tracking-[0.18em] opacity-70">Rows</p>
                      <p class="mt-1 text-4xl font-semibold tracking-tight">
                        {length(panel_rows(panel, @datasets))}
                      </p>
                    </div>
                  <% "timeseries" -> %>
                    <.timeseries_chart
                      id={"chart-#{panel["id"]}"}
                      rows={panel_rows(panel, @datasets)}
                    />
                  <% "bargauge" -> %>
                    <div class="max-h-56 space-y-2 overflow-auto">
                      <div
                        :for={row <- panel_rows(panel, @datasets)}
                        class="grid grid-cols-[minmax(8rem,1fr)_3fr_auto] items-center gap-2 text-xs"
                      >
                        <span class="truncate text-[#cdd6f4]">{series_label(row)}</span>
                        <div class="h-3 border border-[#f9e2af]/20 bg-[#11111b]/60">
                          <div
                            class="h-full bg-gradient-to-r from-[#f9e2af] to-[#fab387]"
                            style={"width: #{bar_height(row)}%"}
                          />
                        </div>
                        <span class="font-semibold text-[#f9e2af]">{format_cell(Map.get(row, "value"))}</span>
                      </div>
                    </div>
                  <% "state-timeline" -> %>
                    <div class="max-h-56 space-y-1.5 overflow-auto">
                      <div
                        :for={row <- panel_rows(panel, @datasets)}
                        class="grid grid-cols-[minmax(10rem,1fr)_4rem_1fr] items-center gap-2 border border-[#b4befe]/10 bg-[#11111b]/35 px-2 py-1.5 text-xs"
                      >
                        <span class="truncate text-[#cdd6f4]">{series_label(row)}</span>
                        <span class={state_class(Map.get(row, "value"))}>{state_label(
                          Map.get(row, "value")
                        )}</span>
                        <span class="truncate text-[#9399b2]">{format_cell(Map.get(row, "time"))}</span>
                      </div>
                    </div>
                  <% _ -> %>
                    <.data_table rows={panel_rows(panel, @datasets)} />
                <% end %>
              <% end %>
            <% end %>
          </article>
        </div>
      </section>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :rows, :list, required: true

  def timeseries_chart(assigns) do
    assigns = assign(assigns, :chart_json, Jason.encode!(chart_payload(assigns.rows)))

    ~H"""
    <div
      id={@id}
      phx-hook="D3Timeseries"
      phx-update="ignore"
      data-chart={@chart_json}
      data-height="160"
      class="relative min-h-40 border border-[#89dceb]/20 bg-[#11111b]/45 p-2"
    />
    """
  end

  attr :rows, :list, required: true

  def data_table(assigns) do
    assigns = assign(assigns, :columns, columns(assigns.rows))

    ~H"""
    <div class="max-h-64 overflow-auto border border-[#b4befe]/15">
      <table class="min-w-full divide-y divide-[#45475a]/70 text-xs">
        <thead class="bg-[#11111b]/60">
          <tr>
            <th
              :for={column <- @columns}
              class="px-2 py-1.5 text-left text-[0.65rem] font-semibold uppercase tracking-[0.14em] text-[#89dceb]"
            >
              {column}
            </th>
          </tr>
        </thead>
        <tbody class="divide-y divide-[#45475a]/50">
          <tr :for={row <- @rows} class="hover:bg-[#313244]/45">
            <td :for={column <- @columns} class="px-2 py-1.5 text-[#cdd6f4]">
              {format_cell(Map.get(row, column))}
            </td>
          </tr>
        </tbody>
      </table>
      <div :if={@rows == []} class="p-3 text-xs text-[#a6adc8]">No rows returned.</div>
    </div>
    """
  end

  defp columns([]), do: []
  defp columns([row | _]), do: Map.keys(row)

  defp panel_rows(%{"dataset" => dataset}, datasets), do: Map.get(datasets, dataset, [])
  defp panel_rows(_panel, _datasets), do: []

  defp panel_loading?(%{"type" => "row"}, _datasets, _loading?), do: false

  defp panel_loading?(%{"dataset" => dataset}, datasets, true),
    do: not Map.has_key?(datasets, dataset)

  defp panel_loading?(_panel, _datasets, _loading?), do: false

  defp panel_error(panel, datasets) do
    case PanelCompatibility.validate(panel, panel_rows(panel, datasets)) do
      :ok -> nil
      {:error, reason} -> reason
    end
  end

  defp format_cell(value) when is_binary(value), do: value
  defp format_cell(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp format_cell(value), do: inspect(value)

  defp series_label(row) do
    row
    |> Map.drop(["time", "value", "raw_value"])
    |> Enum.map(fn {key, value} -> "#{key}=#{value}" end)
    |> Enum.join(" ")
    |> case do
      "" -> "series"
      label -> label
    end
  end

  defp state_label(value) when value in [0, 0.0], do: "Closed"
  defp state_label(value) when value in [1, 1.0], do: "Half Open"
  defp state_label(value) when value in [2, 2.0], do: "Open"
  defp state_label(value), do: format_cell(value)

  defp state_class(value) when value in [0, 0.0],
    do:
      "border border-[#a6e3a1]/20 bg-[#a6e3a1]/10 px-2 py-1 text-xs font-semibold text-[#a6e3a1]"

  defp state_class(value) when value in [1, 1.0],
    do:
      "border border-[#fab387]/20 bg-[#fab387]/10 px-2 py-1 text-xs font-semibold text-[#fab387]"

  defp state_class(value) when value in [2, 2.0],
    do:
      "border border-[#f38ba8]/20 bg-[#f38ba8]/10 px-2 py-1 text-xs font-semibold text-[#f38ba8]"

  defp state_class(_value), do: "mocha-chip px-2 py-1 text-xs font-semibold"

  defp chart_payload(rows) do
    points =
      Enum.filter(rows, &(is_number(Map.get(&1, "time")) and is_number(Map.get(&1, "value"))))

    series =
      points
      |> Enum.group_by(&series_label/1)
      |> Enum.sort_by(fn {label, _rows} -> label end)
      |> Enum.map(fn {label, series_rows} ->
        %{
          label: label,
          points:
            series_rows
            |> Enum.sort_by(& &1["time"])
            |> Enum.map(&[&1["time"], &1["value"]])
        }
      end)

    %{series: series}
  end

  defp bar_height(row) do
    value = Map.get(row, "value", 1)
    value = if is_number(value), do: value, else: 1
    min(max(round(value / 2), 8), 100)
  end
end
