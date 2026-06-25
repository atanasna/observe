defmodule Observe.ExecutorTest do
  use ExUnit.Case, async: true

  alias Observe.Executor

  test "streams each dataset as soon as it is executed" do
    dashboard = %{
      "variables" => %{},
      "datasources" => %{"prometheus" => %{"ref" => "fake-prometheus"}},
      "queries" => %{
        "alpha" => %{"datasource" => "prometheus", "request" => %{"query" => "alpha"}},
        "bravo" => %{"datasource" => "prometheus", "request" => %{"query" => "bravo"}}
      },
      "panels" => []
    }

    assert :ok =
             Executor.run_stream(
               dashboard,
               %{},
               %{datasources: %{"fake-prometheus" => %{"type" => "prometheus"}}},
               &send(self(), {:stream_event, &1})
             )

    events = stream_events([])

    assert [{:plan, _plan} | _events] = events
    assert :complete = List.last(events)

    dataset_names =
      events
      |> Enum.filter(&match?({:dataset, _name, _rows}, &1))
      |> Enum.map(fn {:dataset, name, rows} ->
        assert rows != []
        name
      end)

    assert Enum.sort(dataset_names) == ["alpha", "bravo"]
  end

  test "runs independent source queries in parallel" do
    parent = self()

    task =
      Task.async(fn ->
        Executor.run_stream(
          source_dashboard(),
          %{},
          %{
            datasources: %{"fake-prometheus" => %{"type" => "prometheus"}},
            max_concurrency: 2,
            source_dataset: fn name, _query ->
              send(parent, {:query_started, name, self()})

              receive do
                {:release_query, ^name} -> [%{"value" => name}]
              end
            end
          },
          &send(parent, {:stream_event, &1})
        )
      end)

    assert_receive {:query_started, "alpha", alpha_pid}
    assert_receive {:query_started, "bravo", bravo_pid}

    send(alpha_pid, {:release_query, "alpha"})
    send(bravo_pid, {:release_query, "bravo"})

    assert :ok = Task.await(task)
  end

  test "runs only requested source datasets" do
    assert {:ok, %{datasets: datasets}} =
             Executor.run(source_dashboard(), %{}, %{
               datasources: %{"fake-prometheus" => %{"type" => "prometheus"}},
               only: MapSet.new(["alpha"]),
               source_dataset: fn name, _query -> [%{"value" => name}] end
             })

    assert Map.keys(datasets) == ["alpha"]
  end

  test "includes parents needed by requested derived datasets" do
    dashboard = %{
      "variables" => %{},
      "datasources" => %{"prometheus" => %{"ref" => "fake-prometheus"}},
      "queries" => %{
        "alpha" => %{"datasource" => "prometheus", "request" => %{"query" => "alpha"}},
        "high_alpha" => %{
          "from" => "alpha",
          "transform" => [%{"filter" => %{"field" => "value", "gte" => 2}}]
        }
      },
      "panels" => []
    }

    assert {:ok, %{datasets: datasets}} =
             Executor.run(dashboard, %{}, %{
               datasources: %{"fake-prometheus" => %{"type" => "prometheus"}},
               only: ["high_alpha"],
               source_dataset: fn "alpha", _query -> [%{"value" => 1}, %{"value" => 2}] end
             })

    assert Map.keys(datasets) |> Enum.sort() == ["alpha", "high_alpha"]
    assert datasets["high_alpha"] == [%{"value" => 2}]
  end

  test "normalizes no-value samples from dataset config" do
    dashboard = %{
      "variables" => %{},
      "datasources" => %{"prometheus" => %{"ref" => "fake-prometheus"}},
      "queries" => %{
        "execution_time" => %{"datasource" => "prometheus", "request" => %{"query" => "query"}}
      },
      "datasets" => %{
        "queue_execution_time" => %{"query" => "execution_time", "no_value" => 0}
      },
      "panels" => [
        %{"id" => "execution-time", "type" => "timeseries", "dataset" => "queue_execution_time"}
      ]
    }

    assert {:ok, %{datasets: %{"queue_execution_time" => rows}}} =
             Executor.run(dashboard, %{}, %{
               datasources: %{"fake-prometheus" => %{"type" => "prometheus"}},
               source_dataset: fn "queue_execution_time", _query ->
                 [
                   %{"time" => 1, "value" => "NaN"},
                   %{"time" => 2, "value" => "+Inf"},
                   %{"time" => 3, "value" => "-Inf"},
                   %{"time" => 4, "value" => nil},
                   %{"time" => 5, "value" => 12.5}
                 ]
               end
             })

    assert Enum.map(rows, & &1["value"]) == [0, 0, 0, 0, 12.5]
  end

  test "fills missing samples from dataset config and query interval" do
    dashboard = %{
      "variables" => %{},
      "datasources" => %{"prometheus" => %{"ref" => "fake-prometheus"}},
      "queries" => %{
        "execution_time" => %{
          "datasource" => "prometheus",
          "request" => %{"query" => "query", "range" => true, "interval" => "1m"}
        }
      },
      "datasets" => %{
        "queue_execution_time" => %{"query" => "execution_time", "fill_missing" => 0}
      },
      "panels" => [
        %{"id" => "execution-time", "type" => "timeseries", "dataset" => "queue_execution_time"}
      ]
    }

    assert {:ok, %{datasets: %{"queue_execution_time" => rows}}} =
             Executor.run(dashboard, %{}, %{
               datasources: %{"fake-prometheus" => %{"type" => "prometheus"}},
               time_range: %{from: 60, to: 180},
               source_dataset: fn "queue_execution_time", _query ->
                 [
                   %{"tenant" => "a", "time" => 60, "value" => 1},
                   %{"tenant" => "a", "time" => 180, "value" => 3},
                   %{"tenant" => "b", "time" => 120, "value" => 2}
                 ]
               end
             })

    assert rows_by_series_and_time(rows) == %{
             {"a", 60} => 1,
             {"a", 120} => 0,
             {"a", 180} => 3,
             {"b", 60} => 0,
             {"b", 120} => 2,
             {"b", 180} => 0
           }
  end

  defp source_dashboard do
    %{
      "variables" => %{},
      "datasources" => %{"prometheus" => %{"ref" => "fake-prometheus"}},
      "queries" => %{
        "alpha" => %{"datasource" => "prometheus", "request" => %{"query" => "alpha"}},
        "bravo" => %{"datasource" => "prometheus", "request" => %{"query" => "bravo"}}
      },
      "panels" => []
    }
  end

  defp stream_events(events) do
    receive do
      {:stream_event, event} -> stream_events(events ++ [event])
    after
      0 -> events
    end
  end

  defp rows_by_series_and_time(rows) do
    Map.new(rows, fn row -> {{row["tenant"], row["time"]}, row["value"]} end)
  end
end
