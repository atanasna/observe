defmodule ObserveWeb.DocsLive do
  use ObserveWeb, :live_view

  alias Observe.Docs

  @impl true
  def mount(params, _session, socket) do
    slug = Map.get(params, "slug", Docs.first_slug())
    page = Docs.get(slug) || Docs.get(Docs.first_slug())

    {:ok, assign(socket, pages: Docs.pages(), page: page)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section id="docs-site" class="space-y-6">
        <article class="mocha-shell sharp-corner p-6 md:p-10">
          <div class="border-b border-[#b4befe]/10 pb-8">
            <p class="text-sm font-semibold uppercase tracking-[0.3em] text-[#89dceb]">
              Observe Docs
            </p>
            <h2 class="mocha-heading mt-3 text-4xl font-semibold tracking-tight md:text-5xl">
              {@page.title}
            </h2>
            <p class="mocha-muted mt-4 max-w-3xl text-lg leading-8">{@page.summary}</p>
          </div>

          <div id="docs-content" class="mt-8 space-y-8">
            <.doc_section :for={section <- @page.sections} section={section} />
          </div>
        </article>
      </section>
    </Layouts.app>
    """
  end

  attr :section, :map, required: true

  def doc_section(%{section: %{type: :text}} = assigns) do
    ~H"""
    <p class="max-w-4xl text-base leading-8 text-[#cdd6f4]">{@section.body}</p>
    """
  end

  def doc_section(%{section: %{type: :bullets}} = assigns) do
    ~H"""
    <section>
      <h3 class="text-lg font-semibold text-[#cdd6f4]">{@section.title}</h3>
      <ul class="mt-4 grid gap-3 md:grid-cols-2">
        <li
          :for={item <- @section.items}
          class="border border-[#b4befe]/12 bg-[#11111b]/40 p-4 text-sm leading-6 text-[#bac2de] transition hover:border-[#cba6f7]/35 hover:bg-[#313244]/45"
        >
          {item}
        </li>
      </ul>
    </section>
    """
  end

  def doc_section(%{section: %{type: :code}} = assigns) do
    ~H"""
    <section>
      <h3 class="mb-3 text-lg font-semibold text-[#cdd6f4]">{@section.title}</h3>
      <pre
        phx-no-curly-interpolation
        class="mocha-code overflow-x-auto p-5 text-sm leading-7"
      ><code><%= @section.body %></code></pre>
    </section>
    """
  end

  def doc_section(%{section: %{type: :table}} = assigns) do
    ~H"""
    <section>
      <h3 class="mb-3 text-lg font-semibold text-[#cdd6f4]">{@section.title}</h3>
      <div class="overflow-hidden border border-[#b4befe]/15">
        <table class="min-w-full divide-y divide-[#45475a]/70 text-sm">
          <thead class="bg-[#11111b]/60">
            <tr>
              <th
                :for={header <- @section.headers}
                class="px-4 py-3 text-left text-xs font-semibold uppercase tracking-[0.15em] text-[#89dceb]"
              >
                {header}
              </th>
            </tr>
          </thead>
          <tbody class="divide-y divide-[#45475a]/50">
            <tr
              :for={row <- @section.rows}
              class="align-top hover:bg-[#313244]/45"
            >
              <td :for={cell <- row} class="px-4 py-3 text-[#cdd6f4]">{cell}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  def doc_section(%{section: %{type: :callout}} = assigns) do
    ~H"""
    <section class="border border-[#89dceb]/25 bg-[#89dceb]/10 p-5">
      <h3 class="font-semibold text-[#89dceb]">{@section.title}</h3>
      <p class="mt-2 text-sm leading-7 text-[#cdd6f4]">{@section.body}</p>
    </section>
    """
  end
end
