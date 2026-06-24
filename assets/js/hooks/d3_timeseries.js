import * as d3 from "d3"

const colors = ["#89b4fa", "#cba6f7", "#f5c2e7", "#94e2d5", "#a6e3a1", "#f9e2af", "#fab387", "#f38ba8"]

export const D3Timeseries = {
  mounted() {
    this.selectedLabels = new Set()
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
    const payload = JSON.parse(this.el.dataset.chart || "{\"series\":[]}")
    const style = getComputedStyle(this.el)
    const horizontalPadding = parseFloat(style.paddingLeft || 0) + parseFloat(style.paddingRight || 0)
    const measuredWidth = this.el.getBoundingClientRect().width - horizontalPadding
    const width = Math.max(measuredWidth || 640, 320)
    const fullscreen = document.fullscreenElement === this.el
    const height = fullscreen ? Math.max(window.innerHeight - 120, 320) : Math.max(Number(this.el.dataset.height || 160), 120)
    const margin = {top: 14, right: 12, bottom: 22, left: 42}
    const innerWidth = width - margin.left - margin.right
    const innerHeight = height - margin.top - margin.bottom

    this.el.innerHTML = ""
    this.el.classList.toggle("fixed", fullscreen)
    this.el.classList.toggle("inset-0", fullscreen)
    this.el.classList.toggle("z-[100]", fullscreen)
    this.el.classList.toggle("overflow-auto", fullscreen)
    this.el.classList.toggle("bg-[#11111b]", fullscreen)

    const controls = document.createElement("div")
    controls.className = "mb-2 flex items-center justify-end"
    const fullscreenButton = document.createElement("button")
    fullscreenButton.type = "button"
    fullscreenButton.className = "border border-[#b4befe]/20 bg-[#181825]/80 px-2 py-1 text-[0.65rem] font-semibold uppercase tracking-[0.14em] text-[#bac2de] transition hover:border-[#89dceb]/40 hover:text-[#89dceb]"
    fullscreenButton.textContent = fullscreen ? "Exit fullscreen" : "Fullscreen"
    fullscreenButton.addEventListener("click", () => {
      if (document.fullscreenElement === this.el) {
        document.exitFullscreen()
      } else {
        this.el.requestFullscreen()
      }
    })
    controls.appendChild(fullscreenButton)
    this.el.appendChild(controls)

    if (!payload.series || payload.series.length === 0) {
      const empty = document.createElement("div")
      empty.className = "grid h-40 place-items-center text-xs text-[#9399b2]"
      empty.textContent = "No chartable data returned."
      this.el.appendChild(empty)
      return
    }

    const availableLabels = new Set(payload.series.map(series => series.label))
    this.selectedLabels = new Set([...this.selectedLabels].filter(label => availableLabels.has(label)))

    const hasFocusedSeries = this.selectedLabels.size > 0
    const visibleSeries = hasFocusedSeries
      ? payload.series.filter(series => this.selectedLabels.has(series.label))
      : payload.series

    const allPoints = visibleSeries.flatMap(series => series.points)
    const xExtent = d3.extent(allPoints, point => point[0])
    const yExtent = d3.extent(allPoints, point => point[1])
    const yPadding = yExtent[0] === yExtent[1] ? Math.max(Math.abs(yExtent[0] || 1) * 0.1, 1) : 0

    const x = d3.scaleTime()
      .domain([new Date(xExtent[0] * 1000), new Date(xExtent[1] * 1000)])
      .range([0, innerWidth])

    const y = d3.scaleLinear()
      .domain([yExtent[0] - yPadding, yExtent[1] + yPadding])
      .nice()
      .range([innerHeight, 0])

    const line = d3.line()
      .defined(point => Number.isFinite(point[0]) && Number.isFinite(point[1]))
      .x(point => x(new Date(point[0] * 1000)))
      .y(point => y(point[1]))
      .curve(d3.curveMonotoneX)

    const svg = d3.select(this.el)
      .append("svg")
      .attr("width", "100%")
      .attr("height", height)
      .attr("viewBox", `0 0 ${width} ${height}`)
      .attr("role", "img")
      .style("display", "block")
      .style("max-width", "100%")

    const g = svg.append("g")
      .attr("transform", `translate(${margin.left},${margin.top})`)

    g.append("g")
      .attr("class", "grid")
      .call(d3.axisLeft(y).ticks(4).tickSize(-innerWidth).tickFormat(""))
      .call(group => group.selectAll("line").attr("stroke", "#313244"))
      .call(group => group.select(".domain").remove())

    g.append("g")
      .attr("transform", `translate(0,${innerHeight})`)
      .call(d3.axisBottom(x).ticks(Math.min(5, Math.floor(width / 120))).tickSizeOuter(0))
      .call(group => group.selectAll("text").attr("fill", "#9399b2").attr("font-size", 10))
      .call(group => group.selectAll("line,path").attr("stroke", "#45475a"))

    g.append("g")
      .call(d3.axisLeft(y).ticks(4).tickSizeOuter(0))
      .call(group => group.selectAll("text").attr("fill", "#9399b2").attr("font-size", 10))
      .call(group => group.selectAll("line,path").attr("stroke", "#45475a"))

    visibleSeries.forEach(series => {
      const index = payload.series.findIndex(candidate => candidate.label === series.label)
      g.append("path")
        .datum(series.points)
        .attr("fill", "none")
        .attr("stroke", colors[index % colors.length])
        .attr("stroke-width", 1.8)
        .attr("stroke-linecap", "round")
        .attr("stroke-linejoin", "round")
        .attr("opacity", 0.95)
        .attr("d", line)
    })

    const tooltip = d3.select(this.el)
      .append("div")
      .attr("class", "pointer-events-none absolute hidden max-w-xs border border-[#89dceb]/30 bg-[#11111b]/95 px-3 py-2 text-xs text-[#cdd6f4]")

    const hoverLine = g.append("line")
      .attr("y1", 0)
      .attr("y2", innerHeight)
      .attr("stroke", "#89dceb")
      .attr("stroke-width", 1)
      .attr("opacity", 0)

    const hoverDots = g.append("g").attr("opacity", 0)

    svg.append("rect")
      .attr("x", margin.left)
      .attr("y", margin.top)
      .attr("width", innerWidth)
      .attr("height", innerHeight)
      .attr("fill", "transparent")
      .on("pointermove", event => {
        const [mouseX] = d3.pointer(event, g.node())
        const timestamp = x.invert(mouseX).getTime() / 1000
        const nearest = nearestPoints(visibleSeries, timestamp)
        if (nearest.length === 0) return

        const nearestX = x(new Date(nearest[0].point[0] * 1000))
        hoverLine.attr("x1", nearestX).attr("x2", nearestX).attr("opacity", 0.8)
        hoverDots.attr("opacity", 1)
        hoverDots.selectAll("circle")
          .data(nearest, item => item.series.label)
          .join("circle")
          .attr("cx", item => x(new Date(item.point[0] * 1000)))
          .attr("cy", item => y(item.point[1]))
          .attr("r", 3)
          .attr("fill", item => colors[payload.series.findIndex(series => series.label === item.series.label) % colors.length])
          .attr("stroke", "#11111b")

        const date = new Date(nearest[0].point[0] * 1000)
        tooltip
          .classed("hidden", false)
          .style("left", `${Math.min(event.offsetX + 14, width - 220)}px`)
          .style("top", `${Math.max(event.offsetY - 10, 40)}px`)
          .html([
            `<div class="mb-1 font-semibold text-[#89dceb]">${date.toLocaleString()}</div>`,
            ...nearest.map(item => `<div><span style="color:${colors[payload.series.findIndex(series => series.label === item.series.label) % colors.length]}">●</span> ${escapeHtml(item.series.label)}: <span class="font-semibold">${formatValue(item.point[1])}</span></div>`)
          ].join(""))
      })
      .on("pointerleave", () => {
        hoverLine.attr("opacity", 0)
        hoverDots.attr("opacity", 0)
        tooltip.classed("hidden", true)
      })

    const legend = d3.select(this.el)
      .append("div")
      .attr("class", "mt-2 grid max-h-24 gap-1 overflow-auto text-[0.65rem] md:grid-cols-2")

    payload.series.forEach((series, index) => {
      const isolated = this.selectedLabels.has(series.label)
      const muted = hasFocusedSeries && !isolated
      const item = legend.append("button")
        .attr("type", "button")
        .attr("class", `flex min-w-0 items-center gap-1.5 border border-transparent px-1 py-0.5 text-left transition hover:border-[#89dceb]/25 ${muted ? "opacity-35" : "opacity-100"} ${isolated ? "bg-[#89dceb]/10 text-[#89dceb]" : ""}`)
        .on("click", event => {
          if (event.shiftKey || event.altKey) {
            if (isolated) {
              this.selectedLabels.delete(series.label)
            } else {
              this.selectedLabels.add(series.label)
            }
          } else if (isolated && this.selectedLabels.size === 1) {
            this.selectedLabels.clear()
          } else {
            this.selectedLabels = new Set([series.label])
          }

          this.render()
        })
      item.append("span")
        .attr("class", "size-1.5 shrink-0")
        .style("background", colors[index % colors.length])
      item.append("span")
        .attr("class", "truncate text-[#bac2de]")
        .text(series.label)
    })
  },
}

function nearestPoints(seriesList, timestamp) {
  return seriesList
    .map(series => {
      const point = series.points.reduce((nearest, point) => {
        if (!nearest) return point
        return Math.abs(point[0] - timestamp) < Math.abs(nearest[0] - timestamp) ? point : nearest
      }, null)
      return point ? {series, point} : null
    })
    .filter(Boolean)
    .sort((left, right) => left.series.label.localeCompare(right.series.label))
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
