defmodule ObserveWeb.DashboardShowLive do
  use ObserveWeb, :live_view

  alias Observe.Executor
  alias Observe.PanelCompatibility
  alias Observe.Store
  alias Observe.TimeRange
  alias Observe.Variables

  @var_ref_regex ~r/\$\{vars\.([A-Za-z0-9_\-]+)(?:\.[A-Za-z0-9_\-]+)*\}/

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

        {variable_values, variable_options} =
          Variables.merge_with_options(Map.get(dashboard, "variables", %{}), params, datasources)

        time_range_preset = TimeRange.default()
        time_range = TimeRange.range(time_range_preset)
        datetime_values = TimeRange.datetime_local(time_range)

        {:ok,
         socket
         |> assign(:dashboard, dashboard)
         |> assign(:datasources, datasources)
         |> assign(:variable_values, variable_values)
         |> assign(:variable_options, variable_options)
         |> assign(:start_time, datetime_values.start)
         |> assign(:end_time, datetime_values.end)
         |> assign(:time_range_preset, time_range_preset)
         |> assign(:refresh_interval, "off")
         |> assign(:refresh_timer, nil)
         |> assign(:run_ref, nil)
         |> assign(:run_id, nil)
         |> assign(:last_run_signature, nil)
         |> assign(:run_started_at, nil)
         |> assign(:dashboard_load_ms, nil)
         |> assign(:loading?, false)
         |> assign(:loading_datasets, MapSet.new())
         |> assign(:info_open?, false)
         |> assign(:collapsed_sections, collapsed_sections(dashboard))
         |> assign(:plan, Map.get(dashboard, "plan"))
         |> assign(:datasets, %{})
         |> assign(:error, nil)
         |> start_dashboard_run(variable_values)}
    end
  end

  @impl true
  def handle_event(
        "variables_changed",
        %{"_target" => ["variables", "source"], "variables" => params},
        socket
      ) do
    {variable_values, variable_options, source_value} =
      fast_source_variable_update(socket, params)

    load_deployment_options_async(socket, params, source_value)

    {:noreply,
     socket
     |> assign(:variable_values, variable_values)
     |> assign(:variable_options, variable_options)}
  end

  def handle_event("variables_changed", %{"variables" => params}, socket) do
    {variable_values, variable_options} =
      Variables.merge_with_options(
        Map.get(socket.assigns.dashboard, "variables", %{}),
        params,
        socket.assigns.datasources
      )

    socket =
      socket
      |> assign(:variable_options, variable_options)
      |> start_variable_dashboard_run(variable_values)

    {:noreply, socket}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply,
     socket
     |> sync_relative_time_fields()
     |> start_dashboard_run(socket.assigns.variable_values)}
  end

  def handle_event("select_time_range", %{"range" => range}, socket) do
    if relative_time_range?(range) do
      datetime_values = range |> TimeRange.range() |> TimeRange.datetime_local()

      socket =
        socket
        |> assign(:start_time, datetime_values.start)
        |> assign(:end_time, datetime_values.end)
        |> assign(:time_range_preset, range)
        |> start_dashboard_run(socket.assigns.variable_values)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_panel_section", %{"id" => id}, socket) do
    collapsed_sections =
      if MapSet.member?(socket.assigns.collapsed_sections, id) do
        MapSet.delete(socket.assigns.collapsed_sections, id)
      else
        MapSet.put(socket.assigns.collapsed_sections, id)
      end

    {:noreply, assign(socket, :collapsed_sections, collapsed_sections)}
  end

  def handle_event("toggle_dashboard_info", _params, socket) do
    {:noreply, update(socket, :info_open?, &(!&1))}
  end

  def handle_event("controls_changed", %{"controls" => controls}, socket) do
    start_time = valid_datetime(controls, "start_time", socket.assigns.start_time)
    end_time = valid_datetime(controls, "end_time", socket.assigns.end_time)

    time_range_preset =
      if start_time == socket.assigns.start_time and end_time == socket.assigns.end_time do
        socket.assigns.time_range_preset
      else
        "custom"
      end

    socket =
      socket
      |> assign(:start_time, start_time)
      |> assign(:end_time, end_time)
      |> assign(:time_range_preset, time_range_preset)
      |> assign(
        :refresh_interval,
        Map.get(controls, "refresh_interval", socket.assigns.refresh_interval)
      )
      |> reset_refresh_timer()
      |> start_dashboard_run(socket.assigns.variable_values)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:settle_variables, params}, socket) do
    {variable_values, variable_options} =
      Variables.merge_with_options(
        Map.get(socket.assigns.dashboard, "variables", %{}),
        params,
        socket.assigns.datasources
      )

    socket =
      socket
      |> assign(:variable_options, variable_options)
      |> start_dashboard_run(variable_values)

    {:noreply, socket}
  end

  def handle_info({:deployment_options_loaded, source_value, params, deployment_options}, socket) do
    if socket.assigns.variable_values["source"] == source_value do
      variables = Map.get(socket.assigns.dashboard, "variables", %{})
      deployment_spec = Map.get(variables, "deployment", %{})

      deployment_value =
        selected_variable_value(
          Map.get(params, "deployment"),
          deployment_spec,
          deployment_options
        )

      params = Map.put(params, "deployment", deployment_value)

      send(self(), {:settle_variables, params})

      {:noreply,
       socket
       |> assign(
         :variable_values,
         Map.put(socket.assigns.variable_values, "deployment", deployment_value)
       )
       |> assign(
         :variable_options,
         Map.put(socket.assigns.variable_options, "deployment", deployment_options)
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:poll_dashboard, socket) do
    socket =
      socket
      |> sync_relative_time_fields()
      |> start_dashboard_run(socket.assigns.variable_values, :all, force: true)
      |> schedule_refresh_timer()

    {:noreply, socket}
  end

  def handle_info({:dashboard_plan, run_id, plan}, %{assigns: %{run_id: run_id}} = socket) do
    {:noreply, assign(socket, :plan, plan)}
  end

  def handle_info(
        {:dashboard_dataset, run_id, name, rows},
        %{assigns: %{run_id: run_id}} = socket
      ) do
    {:noreply, update(socket, :datasets, &Map.put(&1, name, rows))}
  end

  def handle_info({:dashboard_complete, run_id}, %{assigns: %{run_id: run_id}} = socket) do
    {:noreply,
     socket
     |> assign(:dashboard_load_ms, elapsed_ms(socket.assigns.run_started_at))
     |> assign(:loading?, false)
     |> assign(:loading_datasets, MapSet.new())}
  end

  def handle_info({:dashboard_plan, _run_id, _plan}, socket), do: {:noreply, socket}

  def handle_info({:dashboard_dataset, _run_id, _name, _rows}, socket), do: {:noreply, socket}

  def handle_info({:dashboard_complete, _run_id}, socket), do: {:noreply, socket}

  def handle_info({ref, result}, %{assigns: %{run_ref: ref}} = socket) do
    Process.demonitor(ref, [:flush])

    socket =
      case result do
        :ok ->
          socket
          |> assign(:error, nil)

        {:error, reason} ->
          socket
          |> assign(:plan, nil)
          |> assign(:datasets, %{})
          |> assign(:loading_datasets, MapSet.new())
          |> assign(:error, reason)
      end

    {:noreply,
     socket
     |> assign(:loading?, false)
     |> assign(:loading_datasets, MapSet.new())
     |> assign(:run_ref, nil)
     |> assign(:run_id, nil)}
  end

  def handle_info({ref, _result}, socket) when is_reference(ref), do: {:noreply, socket}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{assigns: %{run_ref: ref}} = socket) do
    {:noreply,
     socket
     |> assign(:loading?, false)
     |> assign(:loading_datasets, MapSet.new())
     |> assign(:run_ref, nil)
     |> assign(:run_id, nil)
     |> assign(:error, "dashboard run failed: #{inspect(reason)}")}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, socket), do: {:noreply, socket}

  defp start_dashboard_run(socket, variable_values),
    do: start_dashboard_run(socket, variable_values, :all)

  defp start_dashboard_run(socket, variable_values, only, opts \\ []) do
    signature = run_signature(socket, variable_values, only)

    if not Keyword.get(opts, :force, false) and socket.assigns.last_run_signature == signature and
         not socket.assigns.loading? and socket.assigns.datasets != %{} do
      socket
    else
      do_start_dashboard_run(socket, variable_values, only, signature)
    end
  end

  defp do_start_dashboard_run(socket, variable_values, only, signature) do
    caller = self()
    run_id = make_ref()

    opts =
      %{
        time_range: selected_time_range(socket)
      }
      |> maybe_put_only(only)

    task =
      start_query_task(fn ->
        Executor.run_stream(socket.assigns.dashboard, variable_values, opts, fn
          {:plan, plan} -> send(caller, {:dashboard_plan, run_id, plan})
          {:dataset, name, rows} -> send(caller, {:dashboard_dataset, run_id, name, rows})
          :complete -> send(caller, {:dashboard_complete, run_id})
        end)
      end)

    socket
    |> assign(:variable_values, variable_values)
    |> assign(:loading?, true)
    |> assign(:loading_datasets, loading_datasets(only))
    |> assign(:run_started_at, monotonic_ms())
    |> assign(:dashboard_load_ms, nil)
    |> assign(:run_ref, task.ref)
    |> assign(:run_id, run_id)
    |> assign(:last_run_signature, signature)
    |> maybe_clear_datasets(only)
    |> assign(:error, nil)
  end

  defp run_signature(socket, variable_values, only) do
    {selected_time_range(socket), variable_values, only}
  end

  defp maybe_put_only(opts, :all), do: opts
  defp maybe_put_only(opts, only), do: Map.put(opts, :only, only)

  defp loading_datasets(:all), do: nil
  defp loading_datasets(only), do: MapSet.new(only)

  defp maybe_clear_datasets(socket, :all), do: assign(socket, :datasets, %{})

  defp maybe_clear_datasets(socket, only), do: update(socket, :datasets, &Map.drop(&1, only))

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp elapsed_ms(started_at) when is_integer(started_at), do: max(monotonic_ms() - started_at, 0)
  defp elapsed_ms(_started_at), do: nil

  defp start_variable_dashboard_run(socket, variable_values) do
    changed_vars = changed_variables(socket.assigns.variable_values, variable_values)

    cond do
      MapSet.size(changed_vars) == 0 ->
        assign(socket, :variable_values, variable_values)

      MapSet.member?(changed_vars, "source") ->
        start_dashboard_run(socket, variable_values)

      true ->
        affected = affected_datasets(socket.assigns.dashboard, changed_vars)

        if affected == [] do
          assign(socket, :variable_values, variable_values)
        else
          start_dashboard_run(socket, variable_values, affected)
        end
    end
  end

  defp changed_variables(previous, current) do
    previous
    |> Map.keys()
    |> Kernel.++(Map.keys(current))
    |> Enum.uniq()
    |> Enum.reduce(MapSet.new(), fn name, changed ->
      if Map.get(previous, name) == Map.get(current, name) do
        changed
      else
        MapSet.put(changed, name)
      end
    end)
  end

  defp affected_datasets(dashboard, changed_vars) do
    datasets = Map.get(dashboard, "datasets", %{})

    datasets
    |> Enum.filter(fn {_name, dataset} -> depends_on_changed_var?(dataset, changed_vars) end)
    |> Enum.map(fn {name, _dataset} -> name end)
    |> MapSet.new()
    |> include_dependent_datasets(datasets)
    |> MapSet.to_list()
  end

  defp include_dependent_datasets(affected, datasets) do
    next =
      Enum.reduce(datasets, affected, fn {name, dataset}, acc ->
        parent = source_processor_name(dataset) || Map.get(dataset, "from")

        if is_binary(parent) and MapSet.member?(acc, parent) do
          MapSet.put(acc, name)
        else
          acc
        end
      end)

    if MapSet.equal?(next, affected),
      do: affected,
      else: include_dependent_datasets(next, datasets)
  end

  defp depends_on_changed_var?(value, changed_vars) do
    value
    |> variable_refs()
    |> Enum.any?(&MapSet.member?(changed_vars, &1))
  end

  defp variable_refs(value) when is_binary(value) do
    @var_ref_regex
    |> Regex.scan(value)
    |> Enum.map(fn [_match, name] -> name end)
  end

  defp variable_refs(value) when is_map(value) do
    value
    |> Map.drop(["_meta"])
    |> Enum.flat_map(fn {_key, val} -> variable_refs(val) end)
  end

  defp variable_refs(value) when is_list(value), do: Enum.flat_map(value, &variable_refs/1)
  defp variable_refs(_value), do: []

  defp source_processor_name(%{"source" => "processor", "processor" => %{"name" => name}}),
    do: name

  defp source_processor_name(_dataset), do: nil

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
    [{"↻", "off"}, {"10s", "10s"}, {"30s", "30s"}, {"1m", "1m"}, {"5m", "5m"}]
  end

  defp selected_time_range(socket) do
    TimeRange.custom!(socket.assigns.start_time, socket.assigns.end_time)
  rescue
    _ -> TimeRange.range(socket.assigns.time_range_preset)
  end

  defp sync_relative_time_fields(%{assigns: %{time_range_preset: "custom"}} = socket), do: socket

  defp sync_relative_time_fields(%{assigns: %{time_range_preset: preset}} = socket) do
    datetime_values = preset |> TimeRange.range() |> TimeRange.datetime_local()

    socket
    |> assign(:start_time, datetime_values.start)
    |> assign(:end_time, datetime_values.end)
  end

  defp relative_time_range?(range) do
    Enum.any?(TimeRange.options(), fn {_label, value} -> value == range end)
  end

  defp time_range_button_label("custom", start_time, end_time) do
    "#{format_time_range_value(start_time)} to #{format_time_range_value(end_time)}"
  end

  defp time_range_button_label(preset, start_time, end_time) do
    case Enum.find_value(TimeRange.options(), fn {label, value} ->
           if value == preset, do: label
         end) do
      nil -> time_range_button_label("custom", start_time, end_time)
      label -> label
    end
  end

  defp format_time_range_value(value) do
    value
    |> String.replace("T", " ")
    |> String.replace(~r/:00$/, "")
  end

  defp fast_source_variable_update(socket, params) do
    variables = Map.get(socket.assigns.dashboard, "variables", %{})
    source_spec = Map.get(variables, "source", %{})

    source_options =
      Variables.select_options(
        source_spec,
        socket.assigns.datasources,
        socket.assigns.variable_values
      )

    source_value = selected_variable_value(Map.get(params, "source"), source_spec, source_options)

    variable_values =
      socket.assigns.variable_values
      |> Map.merge(params)
      |> Map.put("source", source_value)
      |> Map.put("deployment", "")

    variable_options =
      socket.assigns.variable_options
      |> Map.put("source", source_options)
      |> Map.put("deployment", [{"Loading deployments...", ""}])

    {variable_values, variable_options, source_value}
  end

  defp load_deployment_options_async(socket, params, source_value) do
    caller = self()
    variables = Map.get(socket.assigns.dashboard, "variables", %{})
    deployment_spec = Map.get(variables, "deployment", %{})
    datasources = socket.assigns.datasources
    vars = Map.put(socket.assigns.variable_values, "source", source_value)

    Task.start(fn ->
      deployment_options = Variables.select_options(deployment_spec, datasources, vars)
      send(caller, {:deployment_options_loaded, source_value, params, deployment_options})
    end)
  end

  defp selected_variable_value(requested_value, spec, options) do
    default = Map.get(spec, "default")
    values = Enum.map(options, fn {_label, value} -> value end)

    cond do
      values == [] -> requested_value || default
      requested_value in values -> requested_value
      default in values -> default
      true -> List.first(values)
    end
  end

  defp valid_datetime(controls, key, current_value) do
    value = Map.get(controls, key, current_value)

    if TimeRange.valid_datetime_local?(value), do: value, else: current_value
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} breadcrumbs={dashboard_breadcrumbs(@dashboard)}>
      <section id="dashboard-show" class="space-y-3">
        <div class="dashboard-header-shell mocha-shell sharp-corner p-3 md:p-4">
          <div class="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
            <div>
              <h1 class="mocha-heading text-2xl font-semibold tracking-tight md:text-3xl">
                {get_in(@dashboard, ["metadata", "title"]) || get_in(@dashboard, ["metadata", "name"])}
              </h1>
              <p class="mocha-muted mt-1 text-xs">
                {map_size(Map.get(@dashboard, "queries", %{}))} query nodes · {length(
                  Map.get(@dashboard, "panels", [])
                )} panels
              </p>
            </div>
            <div class="flex flex-wrap items-end gap-2">
              <button
                id="toggle-dashboard-info"
                type="button"
                phx-click="toggle_dashboard_info"
                aria-expanded={to_string(@info_open?)}
                aria-controls="dashboard-info-drawer"
                class={[
                  "grid min-h-8 place-items-center border px-2.5 py-1.5 text-xs font-bold transition focus:outline-none",
                  if(@info_open?,
                    do: "border-[#89dceb]/50 bg-[#89dceb] text-[#11111b]",
                    else:
                      "border-[#b4befe]/15 bg-[#11111b]/55 text-[#89dceb] hover:border-[#89dceb]/50 hover:bg-[#181825]"
                  )
                ]}
              >
                <.icon name="hero-information-circle-micro" class="size-4" />
              </button>
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
                <details
                  id="dashboard-time-picker"
                  phx-hook="TimePicker"
                  class="dashboard-time-picker relative"
                >
                  <summary class="flex min-h-8 cursor-pointer list-none items-center gap-2 border border-[#b4befe]/20 bg-[#11111b]/70 px-3 py-1.5 text-xs font-semibold text-[#cdd6f4] shadow-lg shadow-black/10 transition hover:border-[#89dceb]/50 hover:bg-[#181825] [&::-webkit-details-marker]:hidden">
                    <.icon name="hero-clock-micro" class="size-4 text-[#89dceb]" />
                    <span>{time_range_button_label(@time_range_preset, @start_time, @end_time)}</span>
                    <.icon name="hero-chevron-down-micro" class="size-4 text-[#bac2de]" />
                  </summary>
                  <div class="absolute right-0 top-[calc(100%+0.5rem)] z-50 w-[min(92vw,40rem)] border border-[#89b4fa]/25 bg-[#11111b] text-[#cdd6f4] shadow-2xl shadow-black/50">
                    <div class="grid gap-0 md:grid-cols-[13rem_1fr]">
                      <div class="border-b border-[#b4befe]/15 bg-[#181825]/80 p-2 md:border-b-0 md:border-r">
                        <p class="px-2 py-1 text-[0.65rem] font-semibold uppercase tracking-[0.18em] text-[#89dceb]">
                          Quick ranges
                        </p>
                        <button
                          :for={{label, value} <- TimeRange.options()}
                          type="button"
                          phx-click="select_time_range"
                          phx-value-range={value}
                          data-close-time-picker
                          class={[
                            "block w-full px-2 py-1.5 text-left text-xs font-semibold transition hover:bg-[#313244] hover:text-[#f5c2e7]",
                            @time_range_preset == value && "bg-[#313244] text-[#f5c2e7]"
                          ]}
                        >
                          {label}
                        </button>
                      </div>
                      <div class="space-y-3 p-3">
                        <div>
                          <p class="text-[0.65rem] font-semibold uppercase tracking-[0.18em] text-[#89dceb]">
                            Absolute time range
                          </p>
                          <p class="mt-1 text-[0.7rem] text-[#bac2de]">
                            Set exact UTC start and end times.
                          </p>
                        </div>
                        <div class="grid gap-2 sm:grid-cols-2">
                          <div>
                            <label class="mb-1 block text-[0.65rem] font-semibold uppercase tracking-[0.18em] text-[#89dceb]">
                              From
                            </label>
                            <input
                              id="dashboard-start-time"
                              type="datetime-local"
                              name="controls[start_time]"
                              value={@start_time}
                              class="w-full border border-[#b4befe]/15 bg-[#181825]/80 px-2 py-1.5 text-xs font-semibold text-[#cdd6f4] outline-none transition focus:border-[#cba6f7]/70 focus:bg-[#1e1e2e]"
                            />
                          </div>
                          <div>
                            <label class="mb-1 block text-[0.65rem] font-semibold uppercase tracking-[0.18em] text-[#89dceb]">
                              To
                            </label>
                            <input
                              id="dashboard-end-time"
                              type="datetime-local"
                              name="controls[end_time]"
                              value={@end_time}
                              class="w-full border border-[#b4befe]/15 bg-[#181825]/80 px-2 py-1.5 text-xs font-semibold text-[#cdd6f4] outline-none transition focus:border-[#cba6f7]/70 focus:bg-[#1e1e2e]"
                            />
                          </div>
                        </div>
                        <div class="flex items-center justify-between border-t border-[#b4befe]/15 pt-3">
                          <span class="text-[0.7rem] font-semibold text-[#bac2de]">
                            Times are evaluated in UTC.
                          </span>
                          <button
                            type="button"
                            phx-click="refresh"
                            data-close-time-picker
                            class="border border-[#89dceb]/40 bg-[#89dceb] px-3 py-1.5 text-xs font-bold text-[#11111b] transition hover:bg-[#f5c2e7]"
                          >
                            Apply time range
                          </button>
                        </div>
                      </div>
                    </div>
                  </div>
                </details>
                <div class="flex items-end">
                  <select
                    id="dashboard-refresh-interval"
                    name="controls[refresh_interval]"
                    aria-label="Refresh interval"
                    title="Refresh interval"
                    class="min-h-8 border border-[#b4befe]/15 bg-[#11111b]/55 px-2 py-1.5 text-xs font-semibold text-[#cdd6f4] outline-none transition focus:border-[#cba6f7]/70 focus:bg-[#181825]"
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
            </div>
          </div>

          <.form
            :if={map_size(Map.get(@dashboard, "variables", %{})) > 0}
            for={to_form(%{"variables" => @variable_values})}
            id="dashboard-variables"
            phx-change="variables_changed"
            class="mt-3 grid gap-2 md:grid-cols-4 xl:grid-cols-6"
          >
            <div :for={{name, spec} <- Variables.ordered(Map.get(@dashboard, "variables", %{}))}>
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
                  :for={{label, value} <- Map.get(@variable_options, name, [])}
                  value={value}
                  selected={@variable_values[name] == value}
                >
                  {label}
                </option>
              </select>
            </div>
          </.form>

          <section
            :if={@info_open?}
            id="dashboard-info-drawer"
            class="mocha-card sharp-corner mt-3 grid gap-3 p-3 lg:grid-cols-[0.8fr_1fr]"
          >
            <div>
              <div class="flex items-center justify-between gap-3">
                <h2 class="text-sm font-semibold text-[#cdd6f4]">Applied dashboard plan</h2>
                <span class="text-[0.65rem] font-semibold uppercase tracking-[0.16em] text-[#89dceb]">
                  {plan_status(@plan, @loading?)}
                </span>
              </div>
              <dl class="mt-3 grid gap-1.5 text-xs">
                <div
                  :for={{name, value} <- applied_variables(@plan, @variable_values)}
                  class="grid grid-cols-[7rem_1fr] gap-2 border border-[#b4befe]/10 bg-[#11111b]/35 px-2 py-1.5"
                >
                  <dt class="font-semibold text-[#89dceb]">{name}</dt>
                  <dd class="min-w-0 truncate text-[#cdd6f4]">{format_info_value(value)}</dd>
                </div>
              </dl>
            </div>

            <div class="grid gap-3 xl:grid-cols-2">
              <div>
                <h3 class="text-xs font-bold uppercase tracking-[0.16em] text-[#cba6f7]">
                  Datasets
                </h3>
                <div class="mt-2 max-h-80 space-y-2 overflow-auto pr-1">
                  <div
                    :for={dataset <- applied_datasets(@plan)}
                    id={"dashboard-info-dataset-#{dataset.name}"}
                    class="border border-[#b4befe]/10 bg-[#11111b]/35 p-2 text-xs"
                  >
                    <div class="flex items-center justify-between gap-2">
                      <p class="truncate font-semibold text-[#cdd6f4]">{dataset.name}</p>
                      <span class="shrink-0 text-[0.65rem] uppercase tracking-[0.12em] text-[#f9e2af]">
                        {dataset.kind}
                      </span>
                    </div>
                    <p class="mt-1 truncate text-[#bac2de]">{dataset.detail}</p>
                  </div>
                  <p :if={applied_datasets(@plan) == []} class="text-xs text-[#9399b2]">
                    No datasets planned yet.
                  </p>
                </div>
              </div>

              <div>
                <h3 class="text-xs font-bold uppercase tracking-[0.16em] text-[#f5c2e7]">
                  Queries
                </h3>
                <div class="mt-2 max-h-80 space-y-2 overflow-auto pr-1">
                  <div
                    :for={query <- applied_queries(@plan)}
                    id={"dashboard-info-query-#{query.name}"}
                    class="border border-[#b4befe]/10 bg-[#11111b]/35 p-2 text-xs"
                  >
                    <div class="flex items-center justify-between gap-2">
                      <p class="truncate font-semibold text-[#cdd6f4]">{query.name}</p>
                      <span class="shrink-0 text-[0.65rem] uppercase tracking-[0.12em] text-[#89dceb]">
                        {query.kind}
                      </span>
                    </div>
                    <p :if={query.datasource} class="mt-1 truncate text-[#bac2de]">
                      datasource: {query.datasource}
                    </p>
                    <p :if={query.delay} class="mt-1 truncate text-[#f9e2af]">
                      delay: {query.delay}
                    </p>
                    <code
                      :if={query.query}
                      class="mt-1 block max-h-24 overflow-auto whitespace-pre-wrap border border-[#45475a]/60 bg-[#181825]/70 p-2 text-[0.68rem] leading-4 text-[#a6e3a1]"
                    >{query.query}</code>
                  </div>
                  <p :if={applied_queries(@plan) == []} class="text-xs text-[#9399b2]">
                    No queries planned yet.
                  </p>
                </div>
              </div>
            </div>

            <div class="lg:col-span-2">
              <div class="flex flex-col gap-2 border border-[#b4befe]/10 bg-[#11111b]/25 p-3 md:flex-row md:items-center md:justify-between">
                <div>
                  <h3 class="text-xs font-bold uppercase tracking-[0.16em] text-[#94e2d5]">
                    Datasource requests
                  </h3>
                  <p class="mt-1 text-xs text-[#9399b2]">
                    Detailed datasets, processors, and plan steps are shown inside each panel.
                  </p>
                </div>
                <div id="dashboard-info-request-summary" class="flex flex-wrap gap-1.5 text-xs">
                  <span
                    :for={request <- datasource_request_summary(@plan)}
                    class="border border-[#94e2d5]/20 bg-[#94e2d5]/10 px-2 py-1 font-semibold text-[#94e2d5]"
                  >
                    {request.datasource}: {request.count}
                  </span>
                  <span
                    :if={datasource_request_summary(@plan) == []}
                    class="text-[#9399b2]"
                  >
                    No datasource requests planned.
                  </span>
                </div>
              </div>
            </div>
          </section>
        </div>

        <div
          :if={@error}
          id="dashboard-error"
          class="border border-[#f38ba8]/30 bg-[#f38ba8]/10 p-3 text-xs font-semibold text-[#f38ba8]"
        >
          {@error}
        </div>

        <div
          id="panel-grid"
          class="panel-grid grid gap-3"
          style={"--panel-columns: #{dashboard_columns(@dashboard)}"}
        >
          <article
            :for={panel <- visible_panels(@dashboard, @collapsed_sections)}
            id={"panel-#{panel["id"]}"}
            data-section-collapsed={section_collapsed_attr(panel, @collapsed_sections)}
            data-stacked={stacked_attr(panel)}
            data-legend-position={legend_position(panel)}
            data-layout-width={panel_width(panel, @dashboard)}
            data-layout-height={panel_height(panel, 160)}
            style={"--panel-width: #{panel_width(panel, @dashboard)}"}
            class={[
              if(panel["type"] == "row",
                do: "py-2",
                else: "mocha-card sharp-corner p-3 transition duration-300"
              )
            ]}
          >
            <% panel_loading? = panel_loading?(panel, @datasets, @loading?, @loading_datasets, @plan) %>
            <div
              :if={panel["type"] not in ["row", "timeseries", "sunburst"] and not panel_loading?}
              class="mb-2 flex items-center gap-1.5"
            >
              <h2 class="text-sm font-semibold text-[#cdd6f4]">
                {panel_title(panel, @dashboard, @variable_values, @datasources)}
              </h2>
              <span
                :if={panel_description(panel, @dashboard, @variable_values, @datasources)}
                class="group relative inline-flex items-center"
              >
                <button
                  type="button"
                  aria-label="Panel description"
                  class="grid size-5 place-items-center text-[#89dceb]/80 transition hover:text-[#f5c2e7] focus:outline-none focus:text-[#f5c2e7]"
                >
                  <.icon name="hero-information-circle-micro" class="size-4" />
                </button>
                <span class="pointer-events-none absolute left-1/2 top-5 z-20 hidden w-64 -translate-x-1/2 border border-[#89dceb]/25 bg-[#11111b]/95 px-3 py-2 text-xs font-medium leading-5 text-[#cdd6f4] shadow-xl shadow-[#000]/30 group-hover:block group-focus-within:block">
                  {panel_description(panel, @dashboard, @variable_values, @datasources)}
                </span>
              </span>
            </div>

            <%= if @info_open? and panel["type"] != "row" do %>
              <% panel_info = panel_dependency_summary(@plan, panel, @dashboard) %>
              <details
                id={"panel-info-#{panel["id"]}"}
                class="mb-2 border border-[#94e2d5]/15 bg-[#94e2d5]/5 text-xs"
              >
                <summary class="flex cursor-pointer list-none items-center justify-between gap-3 px-2 py-1.5 font-semibold text-[#94e2d5] [&::-webkit-details-marker]:hidden">
                  <span>Plan details</span>
                  <span class="text-[0.65rem] uppercase tracking-[0.14em] text-[#bac2de]">
                    {panel_info.request_count} requests · {length(panel_info.datasets)} datasets
                  </span>
                </summary>

                <div class="grid gap-2 border-t border-[#94e2d5]/10 p-2 md:grid-cols-2">
                  <div>
                    <p class="font-bold uppercase tracking-[0.14em] text-[#f9e2af]">Datasets</p>
                    <div class="mt-1 flex flex-wrap gap-1">
                      <span
                        :for={dataset <- panel_info.datasets}
                        class="border border-[#f9e2af]/20 bg-[#f9e2af]/10 px-1.5 py-0.5 text-[#f9e2af]"
                      >
                        {dataset.name}{if Map.get(dataset, :reused?), do: " reused", else: ""}
                      </span>
                    </div>
                  </div>
                  <div>
                    <p class="font-bold uppercase tracking-[0.14em] text-[#94e2d5]">
                      Datasource requests
                    </p>
                    <div class="mt-1 flex flex-wrap gap-1">
                      <span
                        :for={request <- panel_info.requests}
                        class="border border-[#94e2d5]/20 bg-[#94e2d5]/10 px-1.5 py-0.5 text-[#94e2d5]"
                      >
                        {request.datasource}: {request.count}
                      </span>
                      <span :if={panel_info.requests == []} class="text-[#9399b2]">none</span>
                    </div>
                  </div>

                  <div class="md:col-span-2">
                    <p class="font-bold uppercase tracking-[0.14em] text-[#cba6f7]">Plan steps</p>
                    <div class="mt-1 grid gap-1 lg:grid-cols-2">
                      <div
                        :for={node <- panel_info.nodes}
                        class="grid grid-cols-[1fr_auto] gap-2 border border-[#45475a]/50 bg-[#181825]/55 px-2 py-1"
                      >
                        <span class="min-w-0 truncate text-[#cdd6f4]">{node.name}</span>
                        <span class="text-[0.65rem] uppercase tracking-[0.12em] text-[#bac2de]">
                          {node.kind}{if node.datasource, do: " / #{node.datasource}", else: ""}
                          {if node.delay, do: " / delay #{node.delay}", else: ""}
                        </span>
                      </div>
                    </div>
                  </div>
                </div>
              </details>
            <% end %>

            <%= if panel_loading? do %>
              <div
                class="flex items-center justify-center gap-3 border border-[#89dceb]/20 bg-[#89dceb]/10 p-4 text-xs font-semibold uppercase tracking-[0.16em] text-[#89dceb]"
                style={loading_panel_style(panel)}
              >
                <span class="inline-block size-4 animate-spin rounded-full border-2 border-[#89dceb]/25 border-t-[#89dceb]" />
                Loading dataset
              </div>
            <% else %>
              <%= if error = panel_error(panel, @datasets, @dashboard) do %>
                <div class="border border-[#f38ba8]/30 bg-[#f38ba8]/10 p-3 text-xs font-semibold leading-5 text-[#f38ba8]">
                  {error}
                </div>
              <% else %>
                <%= case panel["type"] do %>
                  <% "row" -> %>
                    <button
                      id={"section-toggle-#{panel["id"]}"}
                      type="button"
                      phx-click="toggle_panel_section"
                      phx-value-id={panel["id"]}
                      aria-expanded={!section_collapsed?(panel, @collapsed_sections) |> to_string()}
                      class="flex w-full items-center gap-3 text-left text-xs font-semibold uppercase tracking-[0.18em] text-[#cba6f7] focus:outline-none"
                    >
                      <span class="h-px flex-1 bg-[#45475a]/70"></span>
                      <span class="shrink-0">
                        {panel_title(panel, @dashboard, @variable_values, @datasources)}
                      </span>
                      <.icon
                        name={
                          if section_collapsed?(panel, @collapsed_sections),
                            do: "hero-chevron-right-micro",
                            else: "hero-chevron-down-micro"
                        }
                        class="size-4 shrink-0 text-[#cba6f7]"
                      />
                      <span class="h-px flex-1 bg-[#45475a]/70"></span>
                    </button>
                  <% "stat" -> %>
                    <div class="sharp-corner bg-gradient-to-br from-[#cba6f7] via-[#89b4fa] to-[#94e2d5] p-4 text-[#11111b]">
                      <p class="text-xs font-semibold uppercase tracking-[0.18em] opacity-70">Rows</p>
                      <p class="mt-1 text-4xl font-semibold tracking-tight">
                        {length(panel_rows(panel, @datasets, @dashboard))}
                      </p>
                    </div>
                  <% "timeseries" -> %>
                    <.timeseries_chart
                      id={"chart-#{panel["id"]}"}
                      panel={panel}
                      rows={panel_rows(panel, @datasets, @dashboard)}
                      title={panel_title(panel, @dashboard, @variable_values, @datasources)}
                      description={
                        panel_description(panel, @dashboard, @variable_values, @datasources)
                      }
                    />
                  <% "sunburst" -> %>
                    <.sunburst_chart
                      id={"chart-#{panel["id"]}"}
                      panel={panel}
                      rows={panel_rows(panel, @datasets, @dashboard)}
                      title={panel_title(panel, @dashboard, @variable_values, @datasources)}
                      description={
                        panel_description(panel, @dashboard, @variable_values, @datasources)
                      }
                    />
                  <% "bargauge" -> %>
                    <div class="max-h-56 space-y-2 overflow-auto">
                      <div
                        :for={row <- panel_rows(panel, @datasets, @dashboard)}
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
                        :for={row <- panel_rows(panel, @datasets, @dashboard)}
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
                    <.data_table rows={panel_rows(panel, @datasets, @dashboard)} />
                <% end %>
              <% end %>
            <% end %>
          </article>
        </div>

        <% graph_stats = graph_statistics(@plan, @dashboard) %>
        <section
          id="dashboard-graph-stats"
          class="flex flex-wrap items-center gap-x-3 gap-y-1 border border-[#b4befe]/10 bg-[#11111b]/35 px-3 py-2 text-[0.68rem] font-semibold uppercase tracking-[0.12em] text-[#9399b2]"
        >
          <span class="text-[#89dceb]">Graph</span>
          <span id="dashboard-graph-stat-queries">{graph_stats.query_refs} queries</span>
          <span id="dashboard-graph-stat-datasets">{graph_stats.dataset_count} datasets</span>
          <span id="dashboard-graph-stat-execution-nodes">{graph_stats.execution_nodes} nodes</span>
          <span id="dashboard-graph-stat-derived-nodes">{graph_stats.derived_nodes} derived</span>
          <span id="dashboard-graph-stat-reused-datasets">{graph_stats.reused_count} reused</span>
          <span id="dashboard-graph-stat-datasources">{graph_stats.source_nodes} requests</span>
          <span id="dashboard-graph-stat-max-depth">depth {graph_stats.max_depth}</span>
          <span id="dashboard-graph-stat-load-time" class="text-[#f9e2af]">
            loaded {format_duration(@dashboard_load_ms)}
          </span>
        </section>
      </section>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :panel, :map, required: true
  attr :rows, :list, required: true
  attr :title, :string, required: true
  attr :description, :string, default: nil

  def timeseries_chart(assigns) do
    assigns =
      assign(assigns, :chart_json, Jason.encode!(chart_payload(assigns.rows, assigns.panel)))

    assigns = assign(assigns, :stacked, stacked_attr(assigns.panel))
    assigns = assign(assigns, :legend_position, legend_position(assigns.panel))
    assigns = assign(assigns, :height, panel_height(assigns.panel, 160))

    ~H"""
    <div
      id={@id}
      phx-hook="D3Timeseries"
      phx-update="ignore"
      data-chart={@chart_json}
      data-height={@height}
      data-stacked={@stacked}
      data-legend-position={@legend_position}
      data-title={@title}
      data-description={@description}
      class="relative min-h-40"
    />
    """
  end

  attr :id, :string, required: true
  attr :panel, :map, required: true
  attr :rows, :list, required: true
  attr :title, :string, required: true
  attr :description, :string, default: nil

  def sunburst_chart(assigns) do
    assigns =
      assign(assigns, :chart_json, Jason.encode!(sunburst_payload(assigns.rows, assigns.panel)))

    assigns = assign(assigns, :height, panel_height(assigns.panel, 160))

    ~H"""
    <div
      id={@id}
      phx-hook="D3Sunburst"
      phx-update="ignore"
      data-chart={@chart_json}
      data-height={@height}
      data-title={@title}
      data-description={@description}
      class="relative min-h-40"
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
  defp columns([row | _]), do: row |> Map.drop(["legend_format"]) |> Map.keys()

  defp plan_status(nil, true), do: "planning"
  defp plan_status(nil, _loading?), do: "not planned"
  defp plan_status(_plan, true), do: "refreshing"
  defp plan_status(_plan, _loading?), do: "current"

  defp applied_variables(%{variables: variables}, _fallback) when is_map(variables) do
    Enum.sort_by(variables, fn {name, _value} -> name end)
  end

  defp applied_variables(_plan, fallback) do
    Enum.sort_by(fallback || %{}, fn {name, _value} -> name end)
  end

  defp graph_statistics(nil, dashboard) do
    case Map.get(dashboard, "plan") do
      nil -> empty_graph_statistics()
      plan -> graph_statistics(plan, dashboard)
    end
  end

  defp graph_statistics(%{query_order: order, queries: queries} = plan, dashboard) do
    order = order || []
    queries = queries || %{}
    source_nodes = source_nodes(order, queries)
    source_count = length(source_nodes)
    derived_count = Enum.count(order, &(get_in(queries, [&1, "kind"]) == "derived"))
    delayed_count = Enum.count(source_nodes, &Map.has_key?(&1, "delay"))
    transform_count = Enum.count(order, &transform_node?(Map.get(queries, &1, %{})))
    dataset_usage = panel_dataset_usage(Map.get(dashboard, "panels", []))
    reused_datasets = reused_datasets(dataset_usage)
    dataset_refs = Enum.reduce(dataset_usage, 0, fn {_name, count}, total -> total + count end)
    dataset_count = planned_dataset_count(plan, order)
    query_refs = source_query_ref_count(source_nodes)
    max_depth = graph_max_depth(order, queries)

    %{
      query_refs: query_refs,
      dataset_count: dataset_count,
      execution_nodes: length(order),
      derived_nodes: derived_count,
      source_nodes: source_count,
      delayed_nodes: delayed_count,
      reused_count: length(reused_datasets),
      max_depth: max_depth,
      datasources: request_counts(source_nodes),
      reused_datasets: reused_datasets,
      primary: [
        %{
          id: "queries",
          label: "Reusable queries",
          value: query_refs,
          detail: "#{map_size(Map.get(dashboard, "queries", %{}))} definitions available"
        },
        %{
          id: "datasets",
          label: "Datasets",
          value: dataset_count,
          detail: "#{dataset_refs} panel references"
        },
        %{
          id: "execution-nodes",
          label: "Execution nodes",
          value: length(order),
          detail: "#{source_count} source / #{derived_count} derived"
        },
        %{
          id: "derived-nodes",
          label: "Derived nodes",
          value: derived_count,
          detail: "#{transform_count} nodes apply transforms"
        },
        %{
          id: "delayed-nodes",
          label: "Delayed nodes",
          value: delayed_count,
          detail: "historical windows overlaid"
        },
        %{
          id: "reused-datasets",
          label: "Reused datasets",
          value: length(reused_datasets),
          detail: "shared by more than one panel"
        },
        %{
          id: "datasources",
          label: "Datasource requests",
          value: source_count,
          detail: "#{length(request_counts(source_nodes))} datasource aliases"
        },
        %{
          id: "max-depth",
          label: "Max depth",
          value: max_depth,
          detail: "longest dependency path"
        }
      ]
    }
  end

  defp graph_statistics(_plan, _dashboard), do: empty_graph_statistics()

  defp empty_graph_statistics do
    %{
      query_refs: 0,
      dataset_count: 0,
      execution_nodes: 0,
      derived_nodes: 0,
      source_nodes: 0,
      delayed_nodes: 0,
      reused_count: 0,
      max_depth: 0,
      datasources: [],
      reused_datasets: [],
      primary: []
    }
  end

  defp planned_dataset_count(%{datasets: datasets}, order) when is_map(datasets) do
    if map_size(datasets) > 0, do: map_size(datasets), else: length(order)
  end

  defp planned_dataset_count(_plan, order), do: length(order)

  defp source_query_ref_count(source_nodes) do
    source_nodes
    |> Enum.map(
      &(Map.get(&1, "query_ref") || Map.get(&1, "_name") || get_in(&1, ["request", "query"]))
    )
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
    |> MapSet.size()
  end

  defp transform_node?(%{"transform" => transforms})
       when is_list(transforms) and transforms != [],
       do: true

  defp transform_node?(_query), do: false

  defp reused_datasets(dataset_usage) do
    dataset_usage
    |> Enum.filter(fn {_name, count} -> count > 1 end)
    |> Enum.map(fn {name, count} -> %{name: name, count: count} end)
    |> Enum.sort_by(& &1.name)
  end

  defp graph_max_depth([], _queries), do: 0

  defp graph_max_depth(order, queries) do
    order
    |> Enum.map(&node_depth(&1, queries, MapSet.new()))
    |> Enum.max(fn -> 0 end)
  end

  defp node_depth(name, queries, seen) do
    cond do
      MapSet.member?(seen, name) ->
        0

      not Map.has_key?(queries, name) ->
        0

      true ->
        query = Map.fetch!(queries, name)

        case Map.get(query, "from") do
          parent when is_binary(parent) -> 1 + node_depth(parent, queries, MapSet.put(seen, name))
          _parent -> 1
        end
    end
  end

  defp format_duration(nil), do: "pending"
  defp format_duration(ms) when is_integer(ms) and ms < 1_000, do: "#{ms}ms"

  defp format_duration(ms) when is_integer(ms) do
    seconds = ms / 1_000
    :erlang.float_to_binary(seconds, decimals: 2) <> "s"
  end

  defp applied_datasets(nil), do: []

  defp applied_datasets(%{query_order: order, queries: queries}) do
    Enum.map(order || [], fn name ->
      query = Map.get(queries || %{}, name, %{})

      %{
        name: name,
        kind: Map.get(query, "kind", "unknown"),
        detail: dataset_detail(query)
      }
    end)
  end

  defp applied_datasets(_plan), do: []

  defp applied_queries(nil), do: []

  defp applied_queries(%{query_order: order, queries: queries}) do
    Enum.map(order || [], fn name ->
      query = Map.get(queries || %{}, name, %{})

      %{
        name: name,
        kind: Map.get(query, "kind", "unknown"),
        datasource: Map.get(query, "datasource"),
        delay: Map.get(query, "delay"),
        query: query |> get_in(["request", "query"]) |> truncate_info(900)
      }
    end)
  end

  defp applied_queries(_plan), do: []

  defp datasource_request_summary(nil), do: []

  defp datasource_request_summary(%{query_order: order, queries: queries}) do
    order
    |> source_nodes(queries)
    |> request_counts()
  end

  defp datasource_request_summary(_plan), do: []

  defp panel_dependency_summary(nil, panel, _dashboard), do: empty_panel_dependency_summary(panel)

  defp panel_dependency_summary(%{queries: queries} = plan, panel, dashboard) do
    dataset_usage = panel_dataset_usage(Map.get(dashboard, "panels", []))
    panel_dependency_summary(plan, panel, dashboard, dataset_usage, queries || %{})
  end

  defp panel_dependency_summary(_plan, panel, _dashboard),
    do: empty_panel_dependency_summary(panel)

  defp panel_dependency_summary(plan, panel, dashboard, dataset_usage, queries) do
    dataset_names = panel_dataset_names(panel) |> Enum.reject(&is_nil/1)
    nodes = panel_dependency_nodes(dataset_names, queries)
    requests = nodes |> Enum.filter(&(Map.get(&1, "kind") == "source")) |> request_counts()

    %{
      id: Map.get(panel, "id", "panel"),
      title: panel_title(panel, dashboard, plan.variables || %{}, %{}),
      type: Map.get(panel, "type", "panel"),
      datasets:
        Enum.map(dataset_names, fn name ->
          %{name: name, reused?: Map.get(dataset_usage, name, 0) > 1}
        end),
      nodes: Enum.map(nodes, &dependency_node_info/1),
      requests: requests,
      request_count: Enum.reduce(requests, 0, &(&2 + &1.count))
    }
  end

  defp empty_panel_dependency_summary(panel) do
    %{
      id: Map.get(panel, "id", "panel"),
      title: Map.get(panel, "title", Map.get(panel, "id", "panel")),
      type: Map.get(panel, "type", "panel"),
      datasets: [],
      nodes: [],
      requests: [],
      request_count: 0
    }
  end

  defp source_nodes(order, queries) do
    order
    |> Enum.map(&Map.get(queries || %{}, &1, %{}))
    |> Enum.filter(&(Map.get(&1, "kind") == "source"))
  end

  defp request_counts(nodes) do
    nodes
    |> Enum.map(&(Map.get(&1, "datasource") || "unknown"))
    |> Enum.frequencies()
    |> Enum.map(fn {datasource, count} -> %{datasource: datasource, count: count} end)
    |> Enum.sort_by(& &1.datasource)
  end

  defp panel_dependency_nodes(dataset_names, queries) do
    {order, _seen} =
      Enum.reduce(dataset_names, {[], MapSet.new()}, fn name, {order, seen} ->
        collect_dependency_nodes(name, queries, order, seen)
      end)

    Enum.reverse(order)
  end

  defp collect_dependency_nodes(name, queries, order, seen) do
    cond do
      MapSet.member?(seen, name) ->
        {order, seen}

      not Map.has_key?(queries, name) ->
        {order, MapSet.put(seen, name)}

      true ->
        seen = MapSet.put(seen, name)
        query = Map.fetch!(queries, name)

        {order, seen} =
          case Map.get(query, "from") do
            parent when is_binary(parent) ->
              collect_dependency_nodes(parent, queries, order, seen)

            _parent ->
              {order, seen}
          end

        {[Map.put(query, "_name", name) | order], seen}
    end
  end

  defp dependency_node_info(query) do
    %{
      name: Map.get(query, "_name"),
      kind: Map.get(query, "kind", "unknown"),
      datasource: Map.get(query, "datasource"),
      delay: Map.get(query, "delay")
    }
  end

  defp panel_dataset_usage(panels) do
    panels
    |> Enum.reject(&(Map.get(&1, "type") == "row"))
    |> Enum.flat_map(&panel_dataset_names/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
  end

  defp dataset_detail(%{"kind" => "source"} = query) do
    query_ref = Map.get(query, "query_ref")
    datasource = Map.get(query, "datasource")

    detail =
      cond do
        is_binary(query_ref) and is_binary(datasource) -> "#{query_ref} via #{datasource}"
        is_binary(query_ref) -> query_ref
        is_binary(datasource) -> "via #{datasource}"
        true -> "source query"
      end

    append_delay_detail(detail, Map.get(query, "delay"))
  end

  defp dataset_detail(%{"kind" => "derived", "from" => from}) when is_binary(from),
    do: "from #{from}"

  defp dataset_detail(_query), do: "dataset"

  defp append_delay_detail(detail, delay) when is_binary(delay) and delay != "" do
    "#{detail}, delay #{delay}"
  end

  defp append_delay_detail(detail, delay) when is_integer(delay), do: "#{detail}, delay #{delay}s"

  defp append_delay_detail(detail, _delay), do: detail

  defp format_info_value(value) when is_binary(value), do: value
  defp format_info_value(value), do: inspect(value, limit: 20)

  defp truncate_info(nil, _limit), do: nil

  defp truncate_info(value, limit) when is_binary(value) do
    if String.length(value) > limit, do: String.slice(value, 0, limit) <> "...", else: value
  end

  defp truncate_info(value, _limit), do: value

  defp panel_rows(%{"datasets" => panel_datasets}, datasets, dashboard)
       when is_list(panel_datasets) do
    Enum.flat_map(panel_datasets, fn panel_dataset ->
      dataset = panel_dataset_name(panel_dataset)

      datasets
      |> Map.get(dataset, [])
      |> Enum.map(&put_dataset_metadata(&1, dataset, panel_dataset, dashboard))
    end)
  end

  defp panel_rows(%{"dataset" => dataset}, datasets, dashboard) do
    datasets
    |> Map.get(dataset, [])
    |> Enum.map(&put_dataset_metadata(&1, dataset, dataset, dashboard))
  end

  defp panel_rows(_panel, _datasets, _dashboard), do: []

  defp collapsed_sections(dashboard) do
    dashboard
    |> Map.get("panels", [])
    |> Enum.filter(&(Map.get(&1, "type") == "row" and Map.get(&1, "collapsed") == true))
    |> Enum.map(&Map.get(&1, "id"))
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp dashboard_breadcrumbs(dashboard) do
    folder = get_in(dashboard, ["metadata", "folder"])
    title = get_in(dashboard, ["metadata", "title"]) || get_in(dashboard, ["metadata", "name"])

    folder_parts =
      case folder do
        value when is_binary(value) and value not in ["", "root"] ->
          String.split(value, "/", trim: true)

        _folder ->
          []
      end

    folder_parts ++ [title]
  end

  defp visible_panels(dashboard, collapsed_sections) do
    {panels, _collapsed?} =
      dashboard
      |> Map.get("panels", [])
      |> Enum.reduce({[], false}, fn panel, {visible, current_section_collapsed?} ->
        if Map.get(panel, "type") == "row" do
          collapsed? = section_collapsed?(panel, collapsed_sections)
          {[panel | visible], collapsed?}
        else
          if current_section_collapsed? do
            {visible, current_section_collapsed?}
          else
            {[panel | visible], current_section_collapsed?}
          end
        end
      end)

    Enum.reverse(panels)
  end

  defp section_collapsed?(%{"type" => "row", "id" => id}, collapsed_sections),
    do: MapSet.member?(collapsed_sections, id)

  defp section_collapsed?(_panel, _collapsed_sections), do: false

  defp section_collapsed_attr(%{"type" => "row"} = panel, collapsed_sections),
    do: section_collapsed?(panel, collapsed_sections) |> to_string()

  defp section_collapsed_attr(_panel, _collapsed_sections), do: nil

  defp stacked_attr(%{"stacked" => true}), do: "true"
  defp stacked_attr(_panel), do: "false"

  defp dashboard_columns(dashboard) do
    dashboard
    |> get_in(["layout", "columns"])
    |> bounded_integer(3, 1, 16)
  end

  defp panel_width(%{"type" => "row"}, dashboard), do: dashboard_columns(dashboard)

  defp panel_width(panel, dashboard) do
    columns = dashboard_columns(dashboard)

    case get_in(panel, ["layout", "width"]) do
      "full" -> columns
      width -> bounded_integer(width, 1, 1, columns)
    end
  end

  defp panel_height(panel, default) do
    panel
    |> get_in(["layout", "height"])
    |> bounded_integer(default, 120, 800)
  end

  defp loading_panel_style(panel), do: "min-height: #{panel_height(panel, 160)}px"

  defp bounded_integer(value, _default, min, max) when is_integer(value),
    do: value |> Kernel.max(min) |> Kernel.min(max)

  defp bounded_integer(value, default, min, max) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> bounded_integer(integer, default, min, max)
      _invalid -> default
    end
  end

  defp bounded_integer(_value, default, _min, _max), do: default

  defp legend_position(%{"legend" => %{"position" => position}})
       when position in ["top", "bottom", "left", "right"],
       do: position

  defp legend_position(_panel), do: "bottom"

  defp panel_title(panel, dashboard, variable_values, datasources) do
    panel
    |> Map.get("title", Map.get(panel, "id", "Panel"))
    |> interpolate_panel_text(dashboard, variable_values, datasources)
  end

  defp panel_description(%{"description" => description}, dashboard, variable_values, datasources)
       when is_binary(description) and description != "" do
    interpolate_panel_text(description, dashboard, variable_values, datasources)
  end

  defp panel_description(_panel, _dashboard, _variable_values, _datasources), do: nil

  defp interpolate_panel_text(value, dashboard, variable_values, datasources)
       when is_binary(value) do
    dashboard
    |> Map.get("variables", %{})
    |> Variables.context(variable_values, datasources)
    |> then(&Variables.interpolate(value, &1))
  end

  defp interpolate_panel_text(value, _dashboard, _variable_values, _datasources), do: value

  defp panel_loading?(%{"type" => "row"}, _datasets, _loading?, _loading_datasets, _plan),
    do: false

  defp panel_loading?(panel, _datasets, true, %MapSet{} = loading_datasets, plan) do
    if MapSet.size(loading_datasets) > 0 do
      panel
      |> panel_loading_node_names(plan)
      |> Enum.any?(&MapSet.member?(loading_datasets, &1))
    else
      false
    end
  end

  defp panel_loading?(%{"datasets" => panel_datasets}, datasets, true, _loading_datasets, _plan)
       when is_list(panel_datasets),
       do: Enum.any?(panel_datasets, &(not Map.has_key?(datasets, panel_dataset_name(&1))))

  defp panel_loading?(%{"dataset" => dataset}, datasets, true, _loading_datasets, _plan),
    do: not Map.has_key?(datasets, dataset)

  defp panel_loading?(_panel, _datasets, _loading?, _loading_datasets, _plan), do: false

  defp panel_loading_node_names(panel, %{queries: queries}) when is_map(queries) do
    panel
    |> panel_dataset_names()
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(fn name -> [name | dependency_node_names(name, queries, MapSet.new())] end)
    |> Enum.uniq()
  end

  defp panel_loading_node_names(panel, _plan), do: panel_dataset_names(panel)

  defp dependency_node_names(name, queries, seen) do
    cond do
      MapSet.member?(seen, name) ->
        []

      not Map.has_key?(queries, name) ->
        []

      true ->
        query = Map.fetch!(queries, name)

        case Map.get(query, "from") do
          parent when is_binary(parent) ->
            [parent | dependency_node_names(parent, queries, MapSet.put(seen, name))]

          _parent ->
            []
        end
    end
  end

  defp panel_error(panel, datasets, dashboard) do
    case PanelCompatibility.validate(panel, panel_rows(panel, datasets, dashboard)) do
      :ok -> nil
      {:error, reason} -> reason
    end
  end

  defp put_dataset_metadata(row, dataset, panel_dataset, _dashboard) do
    row
    |> Map.put("dataset", dataset)
    |> maybe_put_legend_format(panel_dataset_legend_format(panel_dataset))
  end

  defp panel_dataset_name(dataset) when is_binary(dataset), do: dataset
  defp panel_dataset_name(%{"name" => dataset}) when is_binary(dataset), do: dataset
  defp panel_dataset_name(_dataset), do: nil

  defp panel_dataset_names(%{"datasets" => panel_datasets}) when is_list(panel_datasets),
    do: Enum.map(panel_datasets, &panel_dataset_name/1)

  defp panel_dataset_names(%{"dataset" => dataset}) when is_binary(dataset), do: [dataset]
  defp panel_dataset_names(_panel), do: []

  defp panel_dataset_legend_format(%{"legend" => %{"format" => format}}), do: format
  defp panel_dataset_legend_format(_dataset), do: nil

  defp maybe_put_legend_format(row, format) when is_binary(format) and format != "",
    do: Map.put(row, "legend_format", format)

  defp maybe_put_legend_format(row, _format), do: row

  defp format_cell(value) when is_binary(value), do: value
  defp format_cell(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp format_cell(value), do: inspect(value)

  defp series_label(row) do
    row
    |> Map.drop(["time", "value", "raw_value", "legend_format"])
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

  defp chart_payload(rows, panel) do
    points =
      Enum.filter(rows, &(is_number(Map.get(&1, "time")) and is_number(Map.get(&1, "value"))))

    series =
      points
      |> group_series(panel)
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

  defp sunburst_payload(rows, panel) do
    levels = sunburst_levels(rows, panel)

    root =
      Enum.reduce(rows, %{"name" => "root", "children" => %{}}, fn row, root ->
        value = numeric_value(Map.get(row, "value"))
        path = Enum.map(levels, &to_string(Map.get(row, &1, "unknown")))
        put_sunburst_value(root, path, value)
      end)

    %{
      root: finalize_sunburst_node(root),
      levels: levels,
      rows: Enum.map(rows, &sunburst_payload_row(&1, levels))
    }
  end

  defp sunburst_payload_row(row, levels) do
    %{
      "time" => Map.get(row, "time"),
      "value" => numeric_value(Map.get(row, "value")),
      "path" => Enum.map(levels, &to_string(Map.get(row, &1, "unknown")))
    }
  end

  defp sunburst_levels(_rows, %{"levels" => levels}) when is_list(levels), do: levels

  defp sunburst_levels([], _panel), do: []

  defp sunburst_levels([row | _rows], _panel) do
    row
    |> Map.drop(["time", "value", "raw_value", "dataset", "legend_format"])
    |> Map.keys()
    |> Enum.sort()
  end

  defp put_sunburst_value(node, [], value), do: Map.update(node, "value", value, &(&1 + value))

  defp put_sunburst_value(node, [name | rest], value) do
    children = Map.get(node, "children", %{})
    child = Map.get(children, name, %{"name" => name, "children" => %{}})
    child = put_sunburst_value(child, rest, value)
    Map.put(node, "children", Map.put(children, name, child))
  end

  defp finalize_sunburst_node(%{"children" => children} = node) when map_size(children) > 0 do
    children = children |> Map.values() |> Enum.map(&finalize_sunburst_node/1)

    node
    |> Map.put("children", children)
    |> Map.put("value", Enum.reduce(children, 0, &(&2 + Map.get(&1, "value", 0))))
  end

  defp finalize_sunburst_node(node), do: Map.delete(node, "children")

  defp numeric_value(value) when is_number(value), do: max(value, 0)
  defp numeric_value(_value), do: 0

  defp group_series(points, panel) do
    {order, groups} =
      Enum.reduce(points, {[], %{}}, fn row, {order, groups} ->
        label = series_label(row, panel)

        order = if Map.has_key?(groups, label), do: order, else: [label | order]
        groups = Map.update(groups, label, [row], &[row | &1])

        {order, groups}
      end)

    order
    |> Enum.reverse()
    |> Enum.map(fn label -> {label, groups[label] |> Enum.reverse()} end)
  end

  defp series_label(row, _panel) do
    case Map.get(row, "legend_format") do
      format when is_binary(format) and format != "" -> render_legend_format(format, row)
      _format -> series_label(row)
    end
  end

  defp render_legend_format(format, row) do
    Regex.replace(~r/\{\{\s*([^}\s]+)\s*\}\}/, format, fn _match, key ->
      row
      |> Map.get(key, "")
      |> to_string()
    end)
  end

  defp bar_height(row) do
    value = Map.get(row, "value", 1)
    value = if is_number(value), do: value, else: 1
    min(max(round(value / 2), 8), 100)
  end
end
