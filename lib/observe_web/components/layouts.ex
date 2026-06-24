defmodule ObserveWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use ObserveWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    assigns = assign(assigns, :docs_pages, Observe.Docs.pages())

    ~H"""
    <div class="mocha-grid-bg fixed inset-0 -z-10 opacity-60" />
    <header class="sticky top-0 z-50 flex items-center justify-between border-b border-[#b4befe]/10 bg-[#11111b]/80 px-4 py-3 backdrop-blur-xl sm:px-6 lg:px-8">
      <div class="flex flex-1 items-center gap-3">
        <button
          id="toggle-sidebar"
          type="button"
          aria-label="Toggle navigation"
          class="grid size-10 place-items-center border border-[#b4befe]/20 bg-[#181825]/95 text-[#89dceb] transition hover:border-[#cba6f7]/50 hover:bg-[#313244] hover:text-[#f5c2e7]"
        >
          <span class="flex w-5 flex-col gap-1">
            <span class="h-0.5 w-full bg-current" />
            <span class="h-0.5 w-full bg-current" />
            <span class="h-0.5 w-full bg-current" />
          </span>
        </button>
        <a href="/dashboards" class="flex w-fit items-center gap-3">
          <span class="sharp-corner grid size-10 place-items-center border border-[#f5c2e7]/40 bg-gradient-to-br from-[#cba6f7] via-[#89b4fa] to-[#94e2d5] text-sm font-black text-[#11111b]">O</span>
          <span class="text-sm font-semibold tracking-wide text-[#cdd6f4]">Observe</span>
        </a>
      </div>
      <div class="flex-none">
        <ul class="flex flex-column items-center space-x-2 px-1 sm:space-x-4">
          <li>
            <.theme_toggle />
          </li>
        </ul>
      </div>
    </header>

    <main
      id="app-frame"
      phx-hook="SidebarState"
      class="sidebar-collapsed relative px-4 py-8 sm:px-6 lg:px-8"
    >
      <div>
        <aside
          id="app-sidebar"
          class="app-sidebar mocha-card fixed left-0 top-[4.5rem] z-40 h-[calc(100vh-4.5rem)] w-60 border-l-0 p-3 transition-transform duration-200 ease-out"
        >
          <p class="px-3 py-2 text-xs font-semibold uppercase tracking-[0.24em] text-[#89dceb]">
            Navigation
          </p>
          <nav id="side-navigation" class="mt-2 space-y-1">
            <.link
              navigate={~p"/dashboards"}
              class="group flex items-center justify-between border border-transparent px-3 py-3 text-sm font-semibold text-[#bac2de] transition hover:border-[#f5c2e7]/25 hover:bg-[#313244]/70 hover:text-[#f5c2e7]"
            >
              <span>Dashboards</span>
              <span class="text-[#6c7086] transition group-hover:text-[#f5c2e7]">D</span>
            </.link>
            <.link
              navigate={~p"/datasources"}
              class="group flex items-center justify-between border border-transparent px-3 py-3 text-sm font-semibold text-[#bac2de] transition hover:border-[#89dceb]/25 hover:bg-[#313244]/70 hover:text-[#89dceb]"
            >
              <span>Datasources</span>
              <span class="text-[#6c7086] transition group-hover:text-[#89dceb]">S</span>
            </.link>
            <.link
              navigate={~p"/queries"}
              class="group flex items-center justify-between border border-transparent px-3 py-3 text-sm font-semibold text-[#bac2de] transition hover:border-[#a6e3a1]/25 hover:bg-[#313244]/70 hover:text-[#a6e3a1]"
            >
              <span>Queries</span>
              <span class="text-[#6c7086] transition group-hover:text-[#a6e3a1]">Q</span>
            </.link>
            <details
              id="docs-navigation"
              class="group border border-transparent open:border-[#cba6f7]/20 open:bg-[#181825]/55"
            >
              <summary class="flex cursor-pointer list-none items-center justify-between px-3 py-3 text-sm font-semibold text-[#bac2de] transition hover:bg-[#313244]/70 hover:text-[#cba6f7] [&::-webkit-details-marker]:hidden">
                <span>Docs</span>
                <span class="text-[#6c7086] transition group-open:rotate-90 group-open:text-[#cba6f7]">›</span>
              </summary>
              <div id="docs-nav" class="space-y-1 border-t border-[#cba6f7]/10 px-2 py-2">
                <.link
                  :for={page <- @docs_pages}
                  navigate={~p"/docs/#{page.slug}"}
                  class="block border border-transparent px-3 py-2 text-xs font-semibold text-[#a6adc8] transition hover:border-[#cba6f7]/20 hover:bg-[#313244]/70 hover:text-[#f5c2e7]"
                >
                  {page.title}
                </.link>
              </div>
            </details>
          </nav>
        </aside>
        <div class="app-content min-w-0 space-y-4">
          <div class="mx-auto max-w-7xl">
            {render_slot(@inner_block)}
          </div>
        </div>
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border border-[#b4befe]/20 bg-[#181825]">
      <div class="absolute left-0 h-full w-1/3 border border-[#cba6f7]/30 bg-[#313244] brightness-125 transition-[left] [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
