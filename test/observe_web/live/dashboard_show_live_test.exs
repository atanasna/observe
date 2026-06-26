defmodule ObserveWeb.DashboardShowLiveTest do
  use ObserveWeb.ConnCase

  import Phoenix.LiveViewTest

  test "renders global time and refresh controls", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dashboards/laravel")

    refute has_element?(view, "#dashboard-time-range")
    assert has_element?(view, "#dashboard-start-time")
    assert has_element?(view, "#dashboard-end-time")
    assert has_element?(view, ~s(#dashboard-time-picker[phx-hook="TimePicker"]))
    assert has_element?(view, ~s(#dashboard-time-picker [data-close-time-picker]))
    assert has_element?(view, "#dashboard-refresh-interval")
    assert has_element?(view, "#toggle-dashboard-info")
  end

  test "renders prometheus datasource variable selector", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dashboards/laravel")

    assert has_element?(view, "#variables_source")
    assert render(view) =~ "eu-ds"
    assert render(view) =~ "us-ds"
  end

  test "renders dashboard while datasets are pulled in the background", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dashboards/laravel")

    refute has_element?(view, "#refresh-dashboard")
    assert has_element?(view, "#panel-grid")
    refute has_element?(view, "#dashboard-info-drawer")
  end

  test "shows applied dashboard plan details", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dashboards/queue")

    view
    |> element("#toggle-dashboard-info")
    |> render_click()

    assert has_element?(view, "#dashboard-info-drawer")
    assert has_element?(view, "#dashboard-info-query-queue_default_pending")
    assert has_element?(view, "#dashboard-info-dataset-queue_default_pending")
    assert has_element?(view, "#dashboard-info-request-summary")
    assert has_element?(view, "#panel-info-pending")
    assert has_element?(view, "#panel-info-preasure")
    assert render(view) =~ "Applied dashboard plan"
    assert render(view) =~ "Plan details"
    assert render(view) =~ "prometheus:"
    assert render(view) =~ "queue_jobs_preasure reused"
    assert render(view) =~ "queue_default_jobs_et__queue_jobs_et"
  end

  test "renders queue dashboard with dependent variables and collapsible panel sections", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/dashboards/queue")

    assert render(view) =~ "Applications"
    assert render(view) =~ "Queue"
    assert has_element?(view, "#variables_source")
    assert has_element?(view, "#variables_deployment")
    assert has_element?(view, "#variables_tenant")
    assert has_element?(view, "#panel-pending")
    assert has_element?(view, ~s(#panel-pending[data-stacked="true"]))
    assert has_element?(view, ~s(#panel-pending[data-legend-position="right"]))
    assert has_element?(view, ~s(#panel-pending[data-layout-width="8"]))
    assert has_element?(view, ~s(#panel-pending[data-layout-height="300"]))
    assert has_element?(view, ~s(#panel-running[data-layout-height="300"]))
    assert has_element?(view, ~s(#panel-delayed[data-layout-height="300"]))

    assert has_element?(view, ~s(#panel-ana-metrics[data-section-collapsed="false"]))
    assert has_element?(view, "#panel-execution-time-default")

    view
    |> element("#section-toggle-ana-metrics")
    |> render_click()

    assert has_element?(view, ~s(#panel-ana-metrics[data-section-collapsed="true"]))
    refute has_element?(view, "#panel-execution-time-default")
    refute render(view) =~ "${vars.priority}"
  end
end
