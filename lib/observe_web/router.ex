defmodule ObserveWeb.Router do
  use ObserveWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ObserveWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", ObserveWeb do
    pipe_through :browser

    live "/", DashboardIndexLive
    live "/dashboards", DashboardIndexLive
    live "/dashboards/:name", DashboardShowLive
    live "/queries", QueryIndexLive
    live "/queries/:name", QueryShowLive
    live "/datasources", DatasourceIndexLive
    live "/datasources/:name", DatasourceShowLive
    live "/docs", DocsLive
    live "/docs/:slug", DocsLive
  end

  # Other scopes may use custom stacks.
  # scope "/api", ObserveWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:observe, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: ObserveWeb.Telemetry
    end
  end
end
