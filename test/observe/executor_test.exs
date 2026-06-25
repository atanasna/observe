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
end
