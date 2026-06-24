defmodule Observe.QueryGraphTest do
  use ExUnit.Case, async: true

  alias Observe.Provisioning
  alias Observe.QueryGraph

  test "loads datasources and dashboards recursively with folder metadata" do
    {:ok, datasources} = Provisioning.load_datasources()
    {:ok, queries} = Provisioning.load_queries()
    {:ok, dashboards} = Provisioning.load_dashboards(datasources, queries)

    assert get_in(datasources, ["eu-charge", "_meta", "folder"]) == "real"
    assert get_in(queries, ["request_rate", "_meta", "folder"]) == "services/core"
    assert get_in(dashboards, ["laravel", "_meta", "folder"]) == "applications"
  end

  test "skips invalid dashboards instead of failing the full dashboard load" do
    {:ok, datasources} = Provisioning.load_datasources()
    {:ok, queries} = Provisioning.load_queries()

    assert {:ok, dashboards} = Provisioning.load_dashboards(datasources, queries)
    assert Map.has_key?(dashboards, "laravel")
    refute Map.has_key?(dashboards, "error-explorer")
  end

  test "expands dashboard datasets from query templates with inputs" do
    dashboard = %{
      "variables" => %{},
      "datasources" => %{"prometheus" => %{"ref" => "eu-charge"}},
      "queries" => %{
        "cpu_load" => %{
          "inputs" => %{
            "datasource" => %{"required" => true},
            "group_by" => %{"default" => "instance"}
          },
          "datasource" => "${inputs.datasource}",
          "request" => %{"query" => "avg(rate(cpu[5m])) by (${inputs.group_by})"}
        },
        "hot_nodes" => %{
          "inputs" => %{"from" => %{"default" => "node_cpu"}},
          "from" => "${inputs.from}",
          "transform" => [%{"filter" => %{"field" => "value", "gte" => 75}}]
        }
      },
      "datasets" => %{
        "node_cpu" => %{"query" => "cpu_load", "inputs" => %{"datasource" => "prometheus"}},
        "hot_nodes" => %{"query" => "hot_nodes"}
      },
      "panels" => [%{"id" => "cpu", "type" => "table", "dataset" => "hot_nodes"}]
    }

    assert {:ok, plan} = QueryGraph.plan(dashboard, %{"eu-charge" => %{}})

    assert plan.queries["node_cpu"]["query_ref"] == "cpu_load"
    assert plan.queries["node_cpu"]["datasource"] == "prometheus"
    assert get_in(plan.queries, ["node_cpu", "request", "query"]) =~ "by (instance)"
    assert plan.queries["hot_nodes"]["from"] == "node_cpu"
  end

  test "requires query inputs for dataset expansion" do
    dashboard = %{
      "variables" => %{},
      "datasources" => %{"prometheus" => %{"ref" => "eu-p"}},
      "queries" => %{
        "cpu_load" => %{
          "inputs" => %{"datasource" => %{"required" => true}},
          "datasource" => "${inputs.datasource}",
          "request" => %{"query" => "up"}
        }
      },
      "datasets" => %{"cpu" => %{"query" => "cpu_load"}},
      "panels" => [%{"id" => "cpu", "type" => "table", "dataset" => "cpu"}]
    }

    assert {:error, reason} = QueryGraph.plan(dashboard, %{"eu-p" => %{}})
    assert reason =~ "missing required input datasource"
  end

  test "maps query inputs from dashboard variable formats" do
    dashboard = %{
      "variables" => %{
        "data" => %{
          "type" => "enum",
          "values" => ["eu-charge", "us-charge"],
          "match" => "/(eu|us)-charge/",
          "label" => "$1-ds",
          "formats" => %{"check" => "$1-ds-check", "next" => "$1-ds-next"}
        }
      },
      "datasources" => %{"prometheus" => %{"ref" => "eu-charge"}},
      "queries" => %{
        "metric" => %{
          "inputs" => %{"target" => %{"required" => true}},
          "datasource" => "prometheus",
          "request" => %{"query" => "metric{target=\"${inputs.target}\"}"}
        }
      },
      "datasets" => %{
        "metric_check" => %{
          "query" => "metric",
          "inputs" => %{"target" => "${vars.data.formats.check}"}
        }
      },
      "panels" => [%{"id" => "metric", "type" => "table", "dataset" => "metric_check"}]
    }

    assert {:ok, plan} =
             QueryGraph.plan(dashboard, %{"eu-charge" => %{}}, %{"data" => "us-charge"})

    assert get_in(plan.queries, ["metric_check", "inputs", "target"]) == "us-ds-check"

    assert get_in(plan.queries, ["metric_check", "request", "query"]) ==
             "metric{target=\"us-ds-check\"}"
  end
end
