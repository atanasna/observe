defmodule ObserveWeb.DocsLiveTest do
  use ObserveWeb.ConnCase

  import Phoenix.LiveViewTest

  test "renders documentation index", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/docs")

    assert html =~ "Observe Docs"
    assert html =~ "YAML Reference"
  end

  test "renders YAML reference page", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/docs/yaml-reference")

    assert html =~ "Dashboard top-level keys"
    assert html =~ "metadata"
  end
end
