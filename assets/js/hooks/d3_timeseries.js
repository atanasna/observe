import * as d3 from "d3"

const colors = ["#89b4fa", "#cba6f7", "#f5c2e7", "#94e2d5", "#a6e3a1", "#f9e2af", "#fab387", "#f38ba8"]
const zoomChangedEvent = "observe:timeseries-zoom-changed"
let globalZoomDomain = null
let resetButton = null

export const D3Timeseries = {
  mounted() {
    this.selectedLabels = new Set()
    this.zoomChanged = () => this.scheduleRender()
    this.fullscreenChanged = () => this.scheduleRender()
    window.addEventListener(zoomChangedEvent, this.zoomChanged)
    document.addEventListener("fullscreenchange", this.fullscreenChanged)
    bindGlobalResetButton()
    this.resizeObserver = new ResizeObserver(() => this.scheduleRender())
    this.resizeObserver.observe(this.el)
    this.render()
  },
  updated() {
    this.scheduleRender()
  },
  destroyed() {
    window.removeEventListener(zoomChangedEvent, this.zoomChanged)
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
    const stacked = this.el.dataset.stacked === "true"
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
    controls.className = "mb-2 flex items-center justify-end gap-1.5"

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
    const xDomain = validZoomDomain(globalZoomDomain, xExtent) || xExtent
    const domainSeries = filterSeriesByDomain(visibleSeries, xDomain)
    const domainPoints = domainSeries.flatMap(series => series.points)
    const stackData = stacked ? stackSeries(domainSeries) : null
    const yExtent = stacked
      ? [0, d3.max(stackData.layers, layer => d3.max(layer, point => point[1])) || 1]
      : d3.extent(domainPoints, point => point[1])
    const yPadding = !stacked && yExtent[0] === yExtent[1] ? Math.max(Math.abs(yExtent[0] || 1) * 0.1, 1) : 0

    const x = d3.scaleTime()
      .domain([new Date(xDomain[0] * 1000), new Date(xDomain[1] * 1000)])
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

    if (stacked) {
      const area = d3.area()
        .defined(point => Number.isFinite(point.data.time) && Number.isFinite(point[0]) && Number.isFinite(point[1]))
        .x(point => x(new Date(point.data.time * 1000)))
        .y0(point => y(point[0]))
        .y1(point => y(point[1]))
        .curve(d3.curveMonotoneX)

      stackData.layers.forEach(layer => {
        const index = payload.series.findIndex(candidate => candidate.label === layer.key)
        g.append("path")
          .datum(layer)
          .attr("fill", colors[index % colors.length])
          .attr("fill-opacity", 0.72)
          .attr("stroke", colors[index % colors.length])
          .attr("stroke-width", 1)
          .attr("stroke-linejoin", "round")
          .attr("opacity", 0.95)
          .attr("d", area)
      })
    } else {
      domainSeries.forEach(series => {
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
    }

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

    const showHover = event => {
      const [mouseX] = d3.pointer(event, g.node())
      const timestamp = x.invert(mouseX).getTime() / 1000
      const nearest = nearestPoints(domainSeries, timestamp)
      if (nearest.length === 0) return

      const nearestX = x(new Date(nearest[0].point[0] * 1000))
      hoverLine.attr("x1", nearestX).attr("x2", nearestX).attr("opacity", 0.8)
      hoverDots.attr("opacity", 1)
      hoverDots.selectAll("circle")
        .data(nearest, item => item.series.label)
        .join("circle")
        .attr("cx", item => x(new Date(item.point[0] * 1000)))
        .attr("cy", item => y(stacked ? stackedPointTop(stackData, item.series.label, item.point[0]) : item.point[1]))
        .attr("r", 3)
        .attr("fill", item => colors[payload.series.findIndex(series => series.label === item.series.label) % colors.length])
        .attr("stroke", "#11111b")

      const [tooltipX, tooltipY] = d3.pointer(event, this.el)
      const date = new Date(nearest[0].point[0] * 1000)
      tooltip
        .classed("hidden", false)
        .style("left", `${Math.min(tooltipX + 14, width - 220)}px`)
        .style("top", `${Math.max(tooltipY - 10, 40)}px`)
        .html([
          `<div class="mb-1 font-semibold text-[#89dceb]">${date.toLocaleString()}</div>`,
          ...nearest.map(item => `<div><span style="color:${colors[payload.series.findIndex(series => series.label === item.series.label) % colors.length]}">●</span> ${escapeHtml(item.series.label)}: <span class="font-semibold">${formatValue(item.point[1])}</span></div>`),
          stacked ? `<div class="mt-1 border-t border-[#45475a] pt-1 text-[#bac2de]">Total: <span class="font-semibold">${formatValue(d3.sum(nearest, item => item.point[1]))}</span></div>` : ""
        ].join(""))
    }

    const hideHover = () => {
      hoverLine.attr("opacity", 0)
      hoverDots.attr("opacity", 0)
      tooltip.classed("hidden", true)
    }

    const brush = d3.brushX()
      .extent([[0, 0], [innerWidth, innerHeight]])
      .on("end", event => {
        if (!event.selection) return

        const [start, end] = event.selection
        brushGroup.call(brush.move, null)

        if (Math.abs(end - start) < 8) return

        setGlobalZoomDomain([x.invert(start).getTime() / 1000, x.invert(end).getTime() / 1000])
      })

    const brushGroup = g.append("g")
      .attr("class", "timeseries-brush")
      .call(brush)

    brushGroup.selectAll(".overlay")
      .style("cursor", "crosshair")
      .on("pointermove", showHover)
      .on("pointerleave", hideHover)

    brushGroup.selectAll(".selection")
      .attr("fill", "#89dceb")
      .attr("fill-opacity", 0.18)
      .attr("stroke", "#89dceb")

    const legend = d3.select(this.el)
      .append("div")
      .attr("class", "mt-2 grid max-h-28 gap-1.5 overflow-auto text-xs md:grid-cols-2")

    payload.series.forEach((series, index) => {
      const isolated = this.selectedLabels.has(series.label)
      const muted = hasFocusedSeries && !isolated
      const item = legend.append("button")
        .attr("type", "button")
        .attr("class", `flex min-w-0 items-center gap-2 border border-transparent px-1.5 py-1 text-left transition hover:border-[#89dceb]/25 ${muted ? "opacity-35" : "opacity-100"} ${isolated ? "bg-[#89dceb]/10 text-[#89dceb]" : ""}`)
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
        .attr("class", "size-2 shrink-0")
        .style("background", colors[index % colors.length])
      item.append("span")
        .attr("class", "truncate text-[#bac2de]")
        .text(series.label)
    })
  },
}

function stackSeries(seriesList) {
  const labels = seriesList.map(series => series.label)
  const times = Array.from(new Set(seriesList.flatMap(series => series.points.map(point => point[0])))).sort((left, right) => left - right)
  const valueBySeriesAndTime = new Map()

  seriesList.forEach(series => {
    series.points.forEach(point => {
      valueBySeriesAndTime.set(stackKey(series.label, point[0]), point[1])
    })
  })

  const rows = times.map(time => {
    const row = {time}
    labels.forEach(label => {
      row[label] = valueBySeriesAndTime.get(stackKey(label, time)) || 0
    })
    return row
  })

  const layers = d3.stack().keys(labels)(rows)
  const tops = new Map()
  layers.forEach(layer => {
    layer.forEach(point => {
      tops.set(stackKey(layer.key, point.data.time), point[1])
    })
  })

  return {layers, tops}
}

function stackedPointTop(stackData, label, time) {
  return stackData.tops.get(stackKey(label, time)) || 0
}

function stackKey(label, time) {
  return `${label}\u0000${time}`
}

function bindGlobalResetButton() {
  const button = document.getElementById("reset-timeseries-zoom")
  if (button === resetButton) return
  if (!button) return

  resetButton = button
  button.addEventListener("click", () => setGlobalZoomDomain(null))
  syncResetButton()
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

function setGlobalZoomDomain(domain) {
  globalZoomDomain = domain
  syncResetButton()
  window.dispatchEvent(new CustomEvent(zoomChangedEvent, {detail: {domain}}))
}

function syncResetButton() {
  const button = document.getElementById("reset-timeseries-zoom")
  if (!button) return

  button.classList.toggle("hidden", !globalZoomDomain)
}

function validZoomDomain(zoomDomain, xExtent) {
  if (!zoomDomain || !Number.isFinite(zoomDomain[0]) || !Number.isFinite(zoomDomain[1])) return null
  if (!Number.isFinite(xExtent[0]) || !Number.isFinite(xExtent[1])) return null

  const start = Math.max(Math.min(zoomDomain[0], zoomDomain[1]), xExtent[0])
  const end = Math.min(Math.max(zoomDomain[0], zoomDomain[1]), xExtent[1])

  return end > start ? [start, end] : null
}

function filterSeriesByDomain(seriesList, xDomain) {
  const filtered = seriesList
    .map(series => ({
      ...series,
      points: series.points.filter(point => point[0] >= xDomain[0] && point[0] <= xDomain[1])
    }))
    .filter(series => series.points.length > 0)

  return filtered.length > 0 ? filtered : seriesList
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
