defmodule ObserveWeb.DashboardShowLiveTest do
  use ObserveWeb.ConnCase

  import Phoenix.LiveViewTest

  test "renders global time and refresh controls", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dashboards/laravel")

    refute has_element?(view, "#dashboard-time-range")
    assert has_element?(view, "#dashboard-start-time")
    assert has_element?(view, "#dashboard-end-time")
    assert has_element?(view, "#dashboard-refresh-interval")
    assert has_element?(view, "#reset-timeseries-zoom")
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

    assert has_element?(view, "#refresh-dashboard")
    assert has_element?(view, "#panel-grid")
    assert has_element?(view, "#dashboard-info-drawer")
  end

  test "renders queue dashboard with dependent variables and collapsible panel sections", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/dashboards/queue")

    assert has_element?(view, "#variables_source")
    assert has_element?(view, "#variables_deployment")
    assert has_element?(view, "#variables_tenant")
    assert has_element?(view, "#panel-pending")
    assert has_element?(view, ~s(#panel-pending[data-stacked="true"]))
    assert has_element?(view, ~s(#panel-pending[data-legend-position="bottom"]))
    assert has_element?(view, ~s(#panel-pending[data-layout-width="16"]))
    assert has_element?(view, ~s(#panel-pending[data-layout-height="300"]))
    assert has_element?(view, ~s(#panel-pending button[aria-label="Panel description"]))
    assert has_element?(view, ~s(#panel-experimental[data-section-collapsed="true"]))
    refute has_element?(view, "#panel-jobs-execution-time-default")
    assert render(view) =~ "Pending queue size by priority"

    view
    |> element("#section-toggle-experimental")
    |> render_click()

    assert has_element?(view, ~s(#panel-experimental[data-section-collapsed="false"]))
    assert has_element?(view, "#panel-jobs-execution-time-default")
  end
end
