import * as d3 from "d3"

const colors = ["#89b4fa", "#cba6f7", "#f5c2e7", "#94e2d5", "#a6e3a1", "#f9e2af", "#fab387", "#f38ba8"]

export const D3Sunburst = {
  mounted() {
    this.focusPath = []
    this.fullscreenChanged = () => this.scheduleRender()
    document.addEventListener("fullscreenchange", this.fullscreenChanged)
    this.resizeObserver = new ResizeObserver(() => this.scheduleRender())
    this.resizeObserver.observe(this.el)
    this.render()
  },
  updated() {
    this.scheduleRender()
  },
  destroyed() {
    document.removeEventListener("fullscreenchange", this.fullscreenChanged)
    if (this.resizeObserver) this.resizeObserver.disconnect()
    if (this.frame) cancelAnimationFrame(this.frame)
  },
  scheduleRender() {
    if (this.frame) cancelAnimationFrame(this.frame)
    this.frame = requestAnimationFrame(() => this.render())
  },
  render() {
    this.frame = null
    const payload = JSON.parse(this.el.dataset.chart || "{\"root\":{\"name\":\"root\",\"children\":[]}}")
    const fullscreen = document.fullscreenElement === this.el
    const style = getComputedStyle(this.el)
    const horizontalPadding = parseFloat(style.paddingLeft || 0) + parseFloat(style.paddingRight || 0)
    const width = Math.max(this.el.getBoundingClientRect().width - horizontalPadding, 180)
    const height = fullscreen ? Math.max(window.innerHeight - 110, 360) : Math.max(Number(this.el.dataset.height || 220), 160)
    const size = Math.min(width, height)
    const radius = size / 2

    this.el.innerHTML = ""
    this.el.classList.toggle("fixed", fullscreen)
    this.el.classList.toggle("inset-0", fullscreen)
    this.el.classList.toggle("z-[100]", fullscreen)
    this.el.classList.toggle("overflow-auto", fullscreen)
    this.el.classList.toggle("bg-[#11111b]", fullscreen)

    const controls = document.createElement("div")
    controls.className = "mb-2 flex items-center justify-end gap-1.5"

    const resetButton = iconButton({
      label: "Reset sunburst zoom",
      className: this.focusPath.length > 0
        ? "border-[#fab387]/35 text-[#fab387] hover:border-[#f5c2e7]/45 hover:text-[#f5c2e7]"
        : "border-[#b4befe]/20 text-[#6c7086]",
      icon: resetZoomIcon()
    })
    resetButton.disabled = this.focusPath.length === 0
    resetButton.classList.toggle("cursor-not-allowed", this.focusPath.length === 0)
    resetButton.classList.toggle("opacity-45", this.focusPath.length === 0)
    resetButton.addEventListener("click", () => {
      this.focusPath = []
      this.render()
    })
    controls.appendChild(resetButton)

    const fullscreenButton = iconButton({
      label: fullscreen ? "Exit fullscreen" : "Fullscreen",
      className: "border-[#b4befe]/20 text-[#bac2de] hover:border-[#89dceb]/40 hover:text-[#89dceb]",
      icon: fullscreen ? exitFullscreenIcon() : fullscreenIcon()
    })
    fullscreenButton.addEventListener("click", () => {
      if (document.fullscreenElement === this.el) {
        document.exitFullscreen()
      } else {
        this.el.requestFullscreen()
      }
    })
    controls.appendChild(fullscreenButton)
    this.el.appendChild(controls)

    if (!payload.root || !payload.root.children || payload.root.children.length === 0) {
      const empty = document.createElement("div")
      empty.className = "grid h-40 place-items-center text-xs text-[#9399b2]"
      empty.textContent = "No chartable data returned."
      this.el.appendChild(empty)
      return
    }

    const focusData = focusedData(payload.root, this.focusPath)
    if (!focusData) this.focusPath = []

    const host = document.createElement("div")
    host.className = "grid min-h-40 place-items-center"
    this.el.appendChild(host)

    const rootData = focusData || payload.root
    const root = d3.hierarchy(rootData).sum(d => d.value || 0).sort((a, b) => b.value - a.value)
    d3.partition().size([2 * Math.PI, radius])(root)

    const arc = d3.arc()
      .startAngle(d => d.x0)
      .endAngle(d => d.x1)
      .innerRadius(d => d.y0)
      .outerRadius(d => Math.max(d.y0, d.y1 - 1))

    const svg = d3.select(host)
      .append("svg")
      .attr("width", size)
      .attr("height", size)
      .attr("viewBox", `${-radius} ${-radius} ${size} ${size}`)
      .attr("role", "img")
      .style("display", "block")
      .style("max-width", "100%")

    const tooltip = d3.select(this.el)
      .append("div")
      .attr("class", "pointer-events-none absolute hidden max-w-xs border border-[#cba6f7]/30 bg-[#11111b]/95 px-3 py-2 text-xs text-[#cdd6f4]")

    const nodes = root.descendants().filter(d => d.depth > 0 && d.value > 0)
    const color = d3.scaleOrdinal(colors)

    svg.append("g")
      .selectAll("path")
      .data(nodes)
      .join("path")
      .attr("fill", d => color(topAncestor(d).data.name))
      .attr("fill-opacity", d => Math.max(0.35, 1 - d.depth * 0.14))
      .attr("stroke", "#11111b")
      .attr("stroke-width", 1)
      .attr("cursor", d => d.children ? "pointer" : "default")
      .attr("d", d => arc({...d, x1: d.x0, y1: d.y0}))
      .on("click", (_event, d) => {
        if (!d.children) return
        this.focusPath = [...this.focusPath, d.data.name]
        this.render()
      })
      .on("pointermove", (event, d) => {
        const [x, y] = d3.pointer(event, this.el)
        tooltip
          .classed("hidden", false)
          .style("left", `${Math.min(x + 12, width - 220)}px`)
          .style("top", `${Math.max(y - 8, 8)}px`)
          .html(`<div class="font-semibold text-[#cba6f7]">${escapeHtml(pathLabel(d))}</div><div class="mt-1 text-[#bac2de]">${formatValue(d.value)}</div>`)
      })
      .on("pointerleave", () => tooltip.classed("hidden", true))
      .transition()
      .duration(650)
      .ease(d3.easeCubicOut)
      .attrTween("d", d => {
        const interpolate = d3.interpolate({x0: d.x0, x1: d.x0, y0: d.y0, y1: d.y0}, d)
        return t => arc(interpolate(t))
      })

    svg.append("text")
      .attr("text-anchor", "middle")
      .attr("dy", this.focusPath.length > 0 ? "-0.25em" : "0.1em")
      .attr("fill", "#cdd6f4")
      .attr("font-size", 13)
      .attr("font-weight", 700)
      .text(formatValue(root.value || 0))

    if (this.focusPath.length > 0) {
      svg.append("text")
        .attr("text-anchor", "middle")
        .attr("dy", "1.1em")
        .attr("fill", "#9399b2")
        .attr("font-size", 10)
        .text(this.focusPath[this.focusPath.length - 1])
    }
  },
}

function focusedData(root, path) {
  return path.reduce((node, name) => {
    if (!node || !node.children) return null
    return node.children.find(child => child.name === name) || null
  }, root)
}

function topAncestor(node) {
  let current = node
  while (current.depth > 1) current = current.parent
  return current
}

function pathLabel(node) {
  return node.ancestors().reverse().slice(1).map(d => d.data.name).join(" / ")
}

function formatValue(value) {
  return Number.isFinite(value) ? value.toLocaleString(undefined, {maximumFractionDigits: 3}) : String(value)
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;")
}

function iconButton({label, className, icon}) {
  const button = document.createElement("button")
  button.type = "button"
  button.className = `grid size-7 place-items-center border bg-[#181825]/80 transition ${className}`
  button.setAttribute("aria-label", label)
  button.title = label
  button.innerHTML = icon
  return button
}

function fullscreenIcon() {
  return `<svg viewBox="0 0 20 20" fill="currentColor" aria-hidden="true" class="size-4"><path d="M3.75 3A.75.75 0 0 0 3 3.75v4a.75.75 0 0 0 1.5 0V5.56l3.22 3.22a.75.75 0 0 0 1.06-1.06L5.56 4.5h2.19a.75.75 0 0 0 0-1.5h-4ZM12.25 3a.75.75 0 0 0 0 1.5h2.19l-3.22 3.22a.75.75 0 1 0 1.06 1.06l3.22-3.22v2.19a.75.75 0 0 0 1.5 0v-4a.75.75 0 0 0-.75-.75h-4ZM8.78 12.28a.75.75 0 0 0-1.06-1.06L4.5 14.44v-2.19a.75.75 0 0 0-1.5 0v4c0 .414.336.75.75.75h4a.75.75 0 0 0 0-1.5H5.56l3.22-3.22ZM12.28 11.22a.75.75 0 1 0-1.06 1.06l3.22 3.22h-2.19a.75.75 0 0 0 0 1.5h4a.75.75 0 0 0 .75-.75v-4a.75.75 0 0 0-1.5 0v2.19l-3.22-3.22Z" /></svg>`
}

function exitFullscreenIcon() {
  return `<svg viewBox="0 0 20 20" fill="currentColor" aria-hidden="true" class="size-4"><path d="M8.75 3a.75.75 0 0 1 .75.75v4A.75.75 0 0 1 8.75 8.5h-4a.75.75 0 0 1 0-1.5h2.19L3.72 3.78a.75.75 0 0 1 1.06-1.06L8 5.94V3.75A.75.75 0 0 1 8.75 3ZM11.25 3a.75.75 0 0 1 .75.75v2.19l3.22-3.22a.75.75 0 1 1 1.06 1.06L13.06 7h2.19a.75.75 0 0 1 0 1.5h-4a.75.75 0 0 1-.75-.75v-4A.75.75 0 0 1 11.25 3ZM3.75 11.5h4a.75.75 0 0 1 .75.75v4a.75.75 0 0 1-1.5 0v-2.19l-3.22 3.22a.75.75 0 0 1-1.06-1.06L5.94 13H3.75a.75.75 0 0 1 0-1.5ZM11.25 11.5h4a.75.75 0 0 1 0 1.5h-2.19l3.22 3.22a.75.75 0 1 1-1.06 1.06L12 14.06v2.19a.75.75 0 0 1-1.5 0v-4a.75.75 0 0 1 .75-.75Z" /></svg>`
}

function resetZoomIcon() {
  return `<svg viewBox="0 0 20 20" fill="currentColor" aria-hidden="true" class="size-4"><path fill-rule="evenodd" d="M15.312 11.424a5.5 5.5 0 0 1-9.201 2.466.75.75 0 1 1 1.061-1.06 4 4 0 1 0-1.18-2.83.75.75 0 0 1-1.5 0 5.5 5.5 0 1 1 10.82 1.424Z" clip-rule="evenodd" /><path d="M4.5 3.75a.75.75 0 0 1 .75.75v2.19l2.22-2.22a.75.75 0 0 1 1.06 1.06L5.03 9.03a.75.75 0 0 1-1.28-.53v-4a.75.75 0 0 1 .75-.75Z" /></svg>`
}
