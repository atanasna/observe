defmodule Observe.QueryCache do
  @moduledoc """
  Global in-memory cache for range query source results.

  A small GenServer coordinates interval coverage and single-flight fetches while
  the potentially large row payloads live in ETS. This keeps the cache process
  out of the hot path for row storage.
  """

  use GenServer

  @default_ttl_ms :timer.minutes(15)
  @cleanup_ms :timer.minutes(1)
  @timeout :infinity

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def fetch_range(server \\ __MODULE__, key, %{from: from, to: to, step: step}, fetch_fun)
      when is_function(fetch_fun, 1) and is_integer(step) and step > 0 do
    range = normalize_range(from, to, step)
    GenServer.call(server, {:fetch_range, key, range, fetch_fun}, @timeout)
  end

  def clear(server \\ __MODULE__) do
    GenServer.call(server, :clear)
  end

  def put_range(server \\ __MODULE__, key, %{from: from, to: to, step: step}, rows)
      when is_integer(step) and step > 0 and is_list(rows) do
    range = normalize_range(from, to, step)
    GenServer.call(server, {:put_range, key, range, rows})
  end

  def stats(server \\ __MODULE__) do
    GenServer.call(server, :stats)
  end

  @impl true
  def init(opts) do
    table = :ets.new(:observe_query_cache_rows, [:set, :protected, read_concurrency: true])

    if Keyword.get(opts, :cleanup?, true) do
      Process.send_after(self(), :cleanup, @cleanup_ms)
    end

    {:ok,
     %{
       table: table,
       entries: %{},
       inflight: %{},
       counters: %{hits: 0, misses: 0, fetched_gaps: 0, fetched_rows: 0},
       task_supervisor: Keyword.get(opts, :task_supervisor, Observe.QueryTaskSupervisor),
       ttl_ms: Keyword.get(opts, :ttl_ms, @default_ttl_ms),
       cleanup?: Keyword.get(opts, :cleanup?, true)
     }}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(state.table)

    {:reply, :ok,
     %{
       state
       | entries: %{},
         inflight: %{},
         counters: %{hits: 0, misses: 0, fetched_gaps: 0, fetched_rows: 0}
     }}
  end

  def handle_call(:stats, _from, state) do
    stats = %{
      entries: map_size(state.entries),
      inflight: map_size(state.inflight),
      intervals: state.entries |> Map.values() |> Enum.map(&length(&1.intervals)) |> Enum.sum(),
      rows: :ets.info(state.table, :size),
      hits: state.counters.hits,
      misses: state.counters.misses,
      fetched_gaps: state.counters.fetched_gaps,
      fetched_rows: state.counters.fetched_rows
    }

    {:reply, stats, state}
  end

  def handle_call({:put_range, key, range, rows}, _from, state) do
    write_rows(state.table, key, rows)
    entry = Map.get(state.entries, key, new_entry())

    entry =
      if timestamped_rows?(rows) do
        entry
        |> merge_intervals([range])
        |> touch()
      else
        touch(entry)
      end

    {:reply, :ok, put_in(state.entries[key], entry)}
  end

  def handle_call({:fetch_range, key, range, fetch_fun}, from, state) do
    entry = Map.get(state.entries, key, new_entry())
    gaps = missing_intervals(range, entry.intervals)

    if gaps == [] do
      rows = read_rows(state.table, key, range)

      state =
        state
        |> put_in([:entries, key], touch(entry))
        |> update_counter(:hits, 1)

      {:reply, {:ok, rows}, state}
    else
      inflight_key = {key, gaps}

      case Map.get(state.inflight, inflight_key) do
        nil ->
          task =
            Task.Supervisor.async_nolink(state.task_supervisor, fn ->
              fetch_gaps(gaps, fetch_fun)
            end)

          inflight =
            Map.put(state.inflight, inflight_key, %{
              task_ref: task.ref,
              callers: [{from, range}],
              empty_before?: entry.intervals == []
            })

          state =
            state
            |> put_in([:inflight], inflight)
            |> update_counter(:misses, 1)
            |> update_counter(:fetched_gaps, length(gaps))

          {:noreply, state}

        %{callers: callers} = pending ->
          inflight =
            Map.put(state.inflight, inflight_key, %{pending | callers: [{from, range} | callers]})

          {:noreply, %{state | inflight: inflight}}
      end
    end
  end

  @impl true
  def handle_info({ref, {:ok, fetched}}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {inflight_key, pending} = inflight_by_ref(state.inflight, ref)

    state =
      if pending do
        {key, gaps} = inflight_key
        entry = Map.get(state.entries, key, new_entry())
        write_rows(state.table, key, fetched)

        entry =
          if timestamped_rows?(fetched) do
            entry
            |> merge_intervals(gaps)
            |> touch()
          else
            touch(entry)
          end

        Enum.each(pending.callers, fn {caller, requested_range} ->
          rows =
            if pending.empty_before? and gaps == [requested_range] do
              fetched
            else
              read_rows(state.table, key, requested_range)
            end

          GenServer.reply(caller, {:ok, rows})
        end)

        state
        |> put_in([:entries, key], entry)
        |> update_in([:inflight], &Map.delete(&1, inflight_key))
        |> update_counter(:fetched_rows, length(fetched))
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({ref, {:error, reason}}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, reply_inflight_error(state, ref, reason)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    {:noreply, reply_inflight_error(state, ref, reason)}
  end

  def handle_info(:cleanup, state) do
    now = now_ms()

    {expired, entries} =
      Enum.split_with(state.entries, fn {_key, entry} ->
        now - entry.last_accessed_at > state.ttl_ms
      end)

    Enum.each(expired, fn {key, _entry} -> delete_key_rows(state.table, key) end)

    if state.cleanup? do
      Process.send_after(self(), :cleanup, @cleanup_ms)
    end

    {:noreply, %{state | entries: Map.new(entries)}}
  end

  defp fetch_gaps(gaps, fetch_fun) do
    rows =
      Enum.flat_map(gaps, fn gap ->
        case fetch_fun.(gap) do
          {:ok, rows} when is_list(rows) -> rows
          rows when is_list(rows) -> rows
          {:error, reason} -> throw({:query_cache_error, reason})
        end
      end)

    {:ok, rows}
  catch
    {:query_cache_error, reason} -> {:error, reason}
  end

  defp missing_intervals(range, intervals) do
    {cursor, gaps} =
      intervals
      |> Enum.sort_by(& &1.from)
      |> Enum.reduce_while({range.from, []}, fn interval, {cursor, gaps} ->
        cond do
          cursor > range.to ->
            {:halt, {cursor, gaps}}

          interval.to < cursor ->
            {:cont, {cursor, gaps}}

          interval.from > range.to ->
            {:halt, {cursor, gaps}}

          interval.from > cursor ->
            gap = %{from: cursor, to: min(interval.from - range.step, range.to), step: range.step}
            cursor = max(cursor, interval.to + range.step)
            {:cont, {cursor, [gap | gaps]}}

          true ->
            {:cont, {max(cursor, interval.to + range.step), gaps}}
        end
      end)

    gaps =
      if cursor <= range.to,
        do: [%{from: cursor, to: range.to, step: range.step} | gaps],
        else: gaps

    gaps
    |> Enum.reverse()
    |> Enum.reject(&(&1.from > &1.to))
  end

  defp write_rows(table, key, rows) do
    rows
    |> Enum.filter(&(is_map(&1) and is_number(Map.get(&1, "time"))))
    |> Enum.map(fn row -> {{key, row["time"], series_key(row)}, row} end)
    |> then(fn
      [] -> :ok
      objects -> :ets.insert(table, objects)
    end)
  end

  defp read_rows(table, key, range) do
    table
    |> :ets.match_object({{key, :_, :_}, :_})
    |> Enum.map(fn {{_key, _time, _series}, row} -> row end)
    |> Enum.filter(fn row -> row["time"] >= range.from and row["time"] <= range.to end)
    |> Enum.sort_by(& &1["time"])
  end

  defp delete_key_rows(table, key) do
    table
    |> :ets.match({{key, :_, :_}, :_})
    |> Enum.each(fn [time, series] -> :ets.delete(table, {key, time, series}) end)
  end

  defp series_key(row), do: Map.drop(row, ["time", "value", "raw_value"])

  defp timestamped_rows?(rows) do
    Enum.any?(rows, &(is_map(&1) and is_number(Map.get(&1, "time"))))
  end

  defp merge_intervals(entry, intervals) do
    intervals =
      (entry.intervals ++ intervals)
      |> Enum.sort_by(& &1.from)
      |> Enum.reduce([], fn
        interval, [] ->
          [interval]

        interval, [current | rest] ->
          if interval.from <= current.to + current.step do
            [%{current | to: max(current.to, interval.to)} | rest]
          else
            [interval, current | rest]
          end
      end)
      |> Enum.reverse()

    %{entry | intervals: intervals}
  end

  defp inflight_by_ref(inflight, ref) do
    Enum.find(inflight, fn {_key, pending} -> pending.task_ref == ref end) || {nil, nil}
  end

  defp reply_inflight_error(state, ref, reason) do
    {inflight_key, pending} = inflight_by_ref(state.inflight, ref)

    if pending do
      Enum.each(pending.callers, fn {caller, _range} ->
        GenServer.reply(caller, {:error, reason})
      end)

      update_in(state.inflight, &Map.delete(&1, inflight_key))
    else
      state
    end
  end

  defp normalize_range(from, to, step) when is_number(from) and is_number(to) do
    low = floor(min(from, to))
    high = floor(max(from, to))

    %{from: align_down(low, step), to: align_down(high, step), step: step}
  end

  defp align_down(value, step), do: value - rem(value, step)

  defp new_entry, do: %{intervals: [], last_accessed_at: now_ms()}

  defp touch(entry), do: %{entry | last_accessed_at: now_ms()}

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp update_counter(state, counter, amount) do
    update_in(state.counters[counter], &((&1 || 0) + amount))
  end
end
