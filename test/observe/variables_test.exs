defmodule Observe.VariablesTest do
  use ExUnit.Case, async: false

  alias Observe.Variables

  test "interpolates dashboard variables and environment variables" do
    System.put_env("OBSERVE_TEST_PROM_URL", "https://prometheus.example.test")

    assert Variables.interpolate("${vars.region}-${env.OBSERVE_TEST_PROM_URL}", %{
             "region" => "eu"
           }) ==
             "eu-https://prometheus.example.test"
  after
    System.delete_env("OBSERVE_TEST_PROM_URL")
  end

  test "interpolates variable labels and formats from rich context" do
    variables = %{
      "data" => %{
        "type" => "enum",
        "values" => ["eu-charge", "us-charge"],
        "match" => "/(eu|us)-charge/",
        "label" => "$1-ds",
        "formats" => %{"check" => "$1-ds-check", "next" => "$1-ds-next"}
      }
    }

    context = Variables.context(variables, %{"data" => "eu-charge"})

    assert Variables.interpolate("${vars.data}", context) == "eu-charge"
    assert Variables.interpolate("${vars.data.label}", context) == "eu-ds"
    assert Variables.interpolate("${vars.data.formats.check}", context) == "eu-ds-check"
    assert Variables.interpolate("${vars.data.formats.next}", context) == "eu-ds-next"
  end

  test "interpolates query inputs" do
    assert Variables.interpolate("${inputs.datasource}:${inputs.group_by}", %{}, %{
             "datasource" => "prometheus",
             "group_by" => "namespace,pod"
           }) == "prometheus:namespace,pod"
  end

  test "builds datasource variable options from datasource type" do
    datasources = %{
      "eu-charge" => %{"type" => "prometheus"},
      "logs" => %{"type" => "opensearch"},
      "us-charge" => %{"type" => "prometheus"}
    }

    spec = %{"type" => "datasource", "datasource_type" => "prometheus", "default" => "us-charge"}

    assert Variables.options(spec, datasources) == ["eu-charge", "us-charge"]

    assert Variables.defaults(%{"prometheus_datasource" => spec}, datasources) == %{
             "prometheus_datasource" => "us-charge"
           }
  end

  test "matches datasource variable options by regex" do
    datasources = %{
      "eu-charge" => %{"type" => "prometheus"},
      "internal-prom" => %{"type" => "prometheus"},
      "logs-charge" => %{"type" => "opensearch"},
      "us-charge" => %{"type" => "prometheus"}
    }

    spec = %{
      "type" => "datasource",
      "datasource_type" => "prometheus",
      "match" => ".*-charge$"
    }

    assert Variables.options(spec, datasources) == ["eu-charge", "us-charge"]
  end

  test "extracts datasource variable display labels from regex captures" do
    datasources = %{
      "eu-charge" => %{"type" => "prometheus"},
      "internal-prom" => %{"type" => "prometheus"},
      "us-charge" => %{"type" => "prometheus"}
    }

    spec = %{
      "type" => "datasource",
      "datasource_type" => "prometheus",
      "match" => "/(eu|us)-charge/",
      "label" => "$1-ds"
    }

    assert Variables.select_options(spec, datasources) == [
             {"eu-ds", "eu-charge"},
             {"us-ds", "us-charge"}
           ]

    assert Variables.options(spec, datasources) == ["eu-charge", "us-charge"]
  end

  test "matches and extracts enum variable display labels" do
    spec = %{
      "type" => "enum",
      "values" => ["eu-charge", "internal", "us-charge"],
      "match" => "/(eu|us)-charge/",
      "label" => "$1-region"
    }

    assert Variables.select_options(spec, %{}) == [
             {"eu-region", "eu-charge"},
             {"us-region", "us-charge"}
           ]

    assert Variables.options(spec, %{}) == ["eu-charge", "us-charge"]
  end

  test "invalid datasource variable match expressions return no options" do
    datasources = %{"eu-charge" => %{"type" => "prometheus"}}
    spec = %{"type" => "datasource", "datasource_type" => "prometheus", "match" => "["}

    assert Variables.options(spec, datasources) == []
  end

  test "rejects datasource variable values outside matching datasource options" do
    datasources = %{"eu-charge" => %{"type" => "prometheus"}}

    variables = %{
      "prometheus_datasource" => %{"type" => "datasource", "datasource_type" => "prometheus"}
    }

    assert Variables.merge(variables, %{"prometheus_datasource" => "missing"}, datasources) == %{
             "prometheus_datasource" => "eu-charge"
           }
  end

  test "falls back to the first currently valid dependent variable option" do
    variables = %{
      "source" => %{
        "type" => "enum",
        "values" => ["eu-charge", "us-charge"],
        "default" => "eu-charge"
      },
      "deployment" => %{
        "type" => "enum",
        "values" => ["us-charge"],
        "default" => "eu-charge"
      }
    }

    assert Variables.merge(variables, %{"source" => "us-charge", "deployment" => "eu-charge"}) ==
             %{
               "source" => "us-charge",
               "deployment" => "us-charge"
             }
  end

  test "label values variables are resolved through the selected datasource" do
    datasources = %{
      "eu-charge" => %{"type" => "prometheus"},
      "logs" => %{"type" => "opensearch"}
    }

    spec = %{
      "type" => "label_values",
      "datasource" => "${vars.source}",
      "metric" => "app_queue_low_running_size",
      "metric_label" => "deployment"
    }

    assert Variables.select_options(spec, datasources, %{"source" => "eu-charge"}) == []
    assert Variables.select_options(spec, datasources, %{"source" => "logs"}) == []
  end
end
