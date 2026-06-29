import * as d3 from "d3"

const colors = ["#89b4fa", "#cba6f7", "#f5c2e7", "#94e2d5", "#a6e3a1", "#f9e2af", "#fab387", "#f38ba8"]
const zoomChangedEvent = "observe:timeseries-zoom-changed"
let globalZoomDomain = null

export const D3Timeseries = {
  mounted() {
    this.selectedLabels = new Set()
    this.legendVisible = false
    this.legendWidth = null
    this.zoomChanged = () => this.scheduleRender()
    this.fullscreenChanged = () => this.scheduleRender()
    window.addEventListener(zoomChangedEvent, this.zoomChanged)
    document.addEventListener("fullscreenchange", this.fullscreenChanged)
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
    this.stopLegendResize()
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
    const legendPosition = legendPositionValue(this.el.dataset.legendPosition)
    const sideLegend = this.legendVisible && (legendPosition === "left" || legendPosition === "right")
    const style = getComputedStyle(this.el)
    const horizontalPadding = parseFloat(style.paddingLeft || 0) + parseFloat(style.paddingRight || 0)
    const measuredWidth = this.el.getBoundingClientRect().width - horizontalPadding
    const autoLegendWidth = sideLegend ? sideLegendWidth(payload.series, measuredWidth || 640) : 0
    const legendWidth = sideLegend
      ? this.legendWidth == null
        ? autoLegendWidth
        : constrainedLegendWidth(this.legendWidth, measuredWidth || 640)
      : 0
    const sideLegendGap = sideLegend ? 8 : 0
    const width = Math.max((measuredWidth || 640) - legendWidth - sideLegendGap, 160)
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
    controls.className = "mb-2 flex items-center justify-between gap-2"

    const title = document.createElement("div")
    title.className = "min-w-0 truncate text-sm font-semibold text-[#cdd6f4]"
    title.textContent = this.el.dataset.title || "Timeseries"

    const description = this.el.dataset.description
    if (description) {
      title.title = description
    }

    const actions = document.createElement("div")
    actions.className = "flex shrink-0 items-center justify-end gap-1.5"

    const resetZoomButton = iconButton({
      label: "Reset zoom",
      className: globalZoomDomain
        ? "border-[#fab387]/35 text-[#fab387] hover:border-[#f5c2e7]/45 hover:text-[#f5c2e7]"
        : "border-[#b4befe]/20 text-[#6c7086]",
      icon: resetZoomIcon()
    })
    resetZoomButton.disabled = !globalZoomDomain
    resetZoomButton.classList.toggle("cursor-not-allowed", !globalZoomDomain)
    resetZoomButton.classList.toggle("opacity-45", !globalZoomDomain)
    resetZoomButton.addEventListener("click", () => setGlobalZoomDomain(null))
    actions.appendChild(resetZoomButton)

    const legendButton = iconButton({
      label: this.legendVisible ? "Hide legend" : "Show legend",
      className: this.legendVisible
        ? "border-[#89dceb]/35 text-[#89dceb] hover:border-[#f5c2e7]/45 hover:text-[#f5c2e7]"
        : "border-[#b4befe]/20 text-[#6c7086] hover:border-[#89dceb]/40 hover:text-[#89dceb]",
      icon: legendIcon()
    })
    legendButton.setAttribute("aria-pressed", this.legendVisible ? "true" : "false")
    legendButton.addEventListener("click", () => {
      this.legendVisible = !this.legendVisible
      this.render()
    })
    actions.appendChild(legendButton)

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
    actions.appendChild(fullscreenButton)
    controls.appendChild(title)
    controls.appendChild(actions)
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

    const x = d3.scaleUtc()
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

    const chartBody = document.createElement("div")
    chartBody.className = chartBodyClass(legendPosition)
    this.el.appendChild(chartBody)

    const svgHost = document.createElement("div")
    svgHost.className = "min-w-0 flex-1"
    if (sideLegend) {
      svgHost.style.width = `${width}px`
      svgHost.style.flex = "0 0 auto"
    }

    const legendHost = document.createElement("div")
    legendHost.className = legendClass(legendPosition)
    if (sideLegend) {
      legendHost.style.width = `${legendWidth}px`
      legendHost.style.maxHeight = `${height}px`
    }

    const legendResizeHandle = sideLegend ? this.legendResizeHandle(legendPosition, legendWidth, measuredWidth || 640) : null

    if (!this.legendVisible) {
      chartBody.appendChild(svgHost)
    } else if (legendPosition === "top" || legendPosition === "left") {
      chartBody.appendChild(legendHost)
      if (legendResizeHandle) chartBody.appendChild(legendResizeHandle)
      chartBody.appendChild(svgHost)
    } else {
      chartBody.appendChild(svgHost)
      if (legendResizeHandle) chartBody.appendChild(legendResizeHandle)
      chartBody.appendChild(legendHost)
    }

    const svg = d3.select(svgHost)
      .append("svg")
      .attr("width", width)
      .attr("height", height)
      .attr("viewBox", `0 0 ${width} ${height}`)
      .attr("role", "img")
      .style("display", "block")
      .style("width", sideLegend ? `${width}px` : "100%")
      .style("max-width", sideLegend ? "none" : "100%")

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
      const [mouseX, mouseY] = d3.pointer(event, g.node())
      const nearest = nearestPointForCursor(domainSeries, mouseX, mouseY, x, y, stacked, stackData)
      if (!nearest) return

      hoverLine.attr("x1", mouseX).attr("x2", mouseX).attr("opacity", 0.8)
      hoverDots.attr("opacity", 1)
      hoverDots.selectAll("circle")
        .data([nearest], item => item.series.label)
        .join("circle")
        .attr("cx", item => x(new Date(item.point[0] * 1000)))
        .attr("cy", item => y(stacked ? stackedPointTop(stackData, item.series.label, item.point[0]) : item.point[1]))
        .attr("r", 4)
        .attr("fill", item => colors[payload.series.findIndex(series => series.label === item.series.label) % colors.length])
        .attr("stroke", "#11111b")

      const [tooltipX, tooltipY] = d3.pointer(event, this.el)
      const date = new Date(nearest.point[0] * 1000)
      tooltip
        .classed("hidden", false)
        .style("left", `${Math.min(tooltipX + 14, width - 220)}px`)
        .style("top", `${Math.max(tooltipY - 10, 40)}px`)
        .html([
          `<div class="mb-1 font-semibold text-[#89dceb]">${formatTimestamp(date)}</div>`,
          `<div><span style="color:${colors[payload.series.findIndex(series => series.label === nearest.series.label) % colors.length]}">●</span> ${escapeHtml(nearest.series.label)}: <span class="font-semibold">${formatValue(nearest.point[1])}</span></div>`
        ].join(""))
    }

    const hideHover = () => {
      hoverLine.attr("opacity", 0)
      hoverDots.attr("opacity", 0)
      tooltip.classed("hidden", true)
    }

    const focusNearestSeries = event => {
      if (this.ignoreNextChartClick) {
        this.ignoreNextChartClick = false
        return
      }

      const [mouseX, mouseY] = d3.pointer(event, g.node())
      const nearest = nearestPointForCursor(domainSeries, mouseX, mouseY, x, y, stacked, stackData)
      if (!nearest) return

      this.focusSeries(nearest.series.label, event)
    }

    const brush = d3.brushX()
      .extent([[0, 0], [innerWidth, innerHeight]])
      .on("end", event => {
        if (!event.selection) return

        const [start, end] = event.selection
        brushGroup.call(brush.move, null)

        if (Math.abs(end - start) < 8) return

        this.ignoreNextChartClick = true
        setGlobalZoomDomain([x.invert(start).getTime() / 1000, x.invert(end).getTime() / 1000])
      })

    const brushGroup = g.append("g")
      .attr("class", "timeseries-brush")
      .call(brush)

    brushGroup.selectAll(".overlay")
      .style("cursor", "crosshair")
      .on("pointermove", showHover)
      .on("pointerleave", hideHover)
      .on("click", focusNearestSeries)

    brushGroup.selectAll(".selection")
      .attr("fill", "#89dceb")
      .attr("fill-opacity", 0.18)
      .attr("stroke", "#89dceb")

    if (!this.legendVisible) return

    const legend = d3.select(legendHost)

    payload.series.forEach((series, index) => {
      const isolated = this.selectedLabels.has(series.label)
      const muted = hasFocusedSeries && !isolated
      const item = legend.append("button")
        .attr("type", "button")
        .attr("class", `flex min-w-0 items-center gap-2 border border-transparent px-1.5 py-1 text-left transition hover:border-[#89dceb]/25 ${muted ? "opacity-35" : "opacity-100"} ${isolated ? "bg-[#89dceb]/10 text-[#89dceb]" : ""}`)
        .on("click", event => this.focusSeries(series.label, event))
      item.append("span")
        .attr("class", "size-2 shrink-0")
        .style("background", colors[index % colors.length])
      item.append("span")
        .attr("class", sideLegend ? "whitespace-nowrap text-[#bac2de]" : "truncate text-[#bac2de]")
        .text(series.label)
    })
  },
  legendResizeHandle(position, legendWidth, panelWidth) {
    const handle = document.createElement("button")
    handle.type = "button"
    handle.className = "group hidden w-2 cursor-col-resize touch-none self-stretch md:flex md:items-stretch md:justify-center"
    handle.setAttribute("aria-label", "Resize legend")
    handle.title = "Drag to resize legend"
    handle.innerHTML = '<span class="my-1 block w-px bg-[#45475a] transition group-hover:bg-[#89dceb]"></span>'
    handle.addEventListener("pointerdown", event => this.startLegendResize(event, position, legendWidth, panelWidth))
    return handle
  },
  focusSeries(label, event) {
    const isolated = this.selectedLabels.has(label)

    if (event.shiftKey || event.altKey) {
      if (isolated) {
        this.selectedLabels.delete(label)
      } else {
        this.selectedLabels.add(label)
      }
    } else if (isolated && this.selectedLabels.size === 1) {
      this.selectedLabels.clear()
    } else {
      this.selectedLabels = new Set([label])
    }

    this.render()
  },
  startLegendResize(event, position, legendWidth, panelWidth) {
    event.preventDefault()
    event.currentTarget.setPointerCapture?.(event.pointerId)
    this.stopLegendResize()

    this.legendResize = {
      position,
      panelWidth,
      startX: event.clientX,
      startWidth: legendWidth,
      bodyCursor: document.body.style.cursor,
      bodyUserSelect: document.body.style.userSelect
    }
    this.legendResizeMove = event => this.updateLegendResize(event)
    this.legendResizeUp = () => this.stopLegendResize()
    document.body.style.cursor = "col-resize"
    document.body.style.userSelect = "none"
    window.addEventListener("pointermove", this.legendResizeMove)
    window.addEventListener("pointerup", this.legendResizeUp, {once: true})
  },
  updateLegendResize(event) {
    if (!this.legendResize) return

    const delta = event.clientX - this.legendResize.startX
    const direction = this.legendResize.position === "left" ? 1 : -1
    this.legendWidth = constrainedLegendWidth(
      this.legendResize.startWidth + delta * direction,
      this.legendResize.panelWidth
    )
    this.scheduleRender()
  },
  stopLegendResize() {
    if (this.legendResizeMove) window.removeEventListener("pointermove", this.legendResizeMove)
    if (this.legendResizeUp) window.removeEventListener("pointerup", this.legendResizeUp)
    if (this.legendResize) {
      document.body.style.cursor = this.legendResize.bodyCursor
      document.body.style.userSelect = this.legendResize.bodyUserSelect
    }
    this.legendResize = null
    this.legendResizeMove = null
    this.legendResizeUp = null
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

function legendPositionValue(value) {
  return ["top", "bottom", "left", "right"].includes(value) ? value : "bottom"
}

function chartBodyClass(position) {
  if (position === "left" || position === "right") {
    return "flex min-w-0 flex-col gap-2 md:flex-row"
  }

  return "flex min-w-0 flex-col gap-2"
}

function legendClass(position) {
  if (position === "left" || position === "right") {
    return "grid max-h-40 content-start items-start gap-0.5 overflow-auto text-xs md:shrink-0 md:grid-cols-1"
  }

  return "flex max-h-20 flex-wrap items-center gap-1.5 overflow-auto text-xs"
}

function sideLegendWidth(seriesList, panelWidth) {
  const maxWidth = panelWidth * 0.5
  const measuredWidth = d3.max(seriesList, series => textWidth(series.label)) || 0

  return Math.min(Math.ceil(measuredWidth + 38), maxWidth)
}

function constrainedLegendWidth(width, panelWidth) {
  const maxWidth = Math.max(80, Math.min(panelWidth * 0.7, panelWidth - 168))
  const minWidth = Math.min(96, maxWidth)

  return Math.max(minWidth, Math.min(Math.ceil(width), maxWidth))
}

function textWidth(value) {
  const canvas = textWidth.canvas || (textWidth.canvas = document.createElement("canvas"))
  const context = canvas.getContext("2d")
  context.font = "600 12px ui-sans-serif, system-ui, sans-serif"

  return context.measureText(String(value)).width
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

function legendIcon() {
  return `<svg viewBox="0 0 20 20" fill="currentColor" aria-hidden="true" class="size-4"><path d="M4 5.25A1.25 1.25 0 1 1 1.5 5.25 1.25 1.25 0 0 1 4 5.25ZM6.25 4.5a.75.75 0 0 0 0 1.5h11.5a.75.75 0 0 0 0-1.5H6.25ZM6.25 9.25a.75.75 0 0 0 0 1.5h11.5a.75.75 0 0 0 0-1.5H6.25ZM5.5 14.75a.75.75 0 0 1 .75-.75h11.5a.75.75 0 0 1 0 1.5H6.25a.75.75 0 0 1-.75-.75ZM2.75 11.25a1.25 1.25 0 1 0 0-2.5 1.25 1.25 0 0 0 0 2.5ZM4 14.75a1.25 1.25 0 1 1-2.5 0 1.25 1.25 0 0 1 2.5 0Z" /></svg>`
}

function resetZoomIcon() {
  return `<svg viewBox="0 0 20 20" fill="currentColor" aria-hidden="true" class="size-4"><path fill-rule="evenodd" d="M15.312 11.424a5.5 5.5 0 0 1-9.201 2.466.75.75 0 1 1 1.061-1.06 4 4 0 1 0-1.18-2.83.75.75 0 0 1-1.5 0 5.5 5.5 0 1 1 10.82 1.424Z" clip-rule="evenodd" /><path d="M4.5 3.75a.75.75 0 0 1 .75.75v2.19l2.22-2.22a.75.75 0 0 1 1.06 1.06L5.03 9.03a.75.75 0 0 1-1.28-.53v-4a.75.75 0 0 1 .75-.75Z" /></svg>`
}

function setGlobalZoomDomain(domain) {
  globalZoomDomain = domain
  window.dispatchEvent(new CustomEvent(zoomChangedEvent, {detail: {domain}}))
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

function nearestPointForCursor(seriesList, mouseX, mouseY, x, y, stacked, stackData) {
  return seriesList
    .flatMap(series => series.points.map(point => {
      const pointX = x(new Date(point[0] * 1000))
      const pointY = y(stacked ? stackedPointTop(stackData, series.label, point[0]) : point[1])

      return {
        series,
        point,
        distance: Math.hypot(pointX - mouseX, pointY - mouseY)
      }
    }))
    .filter(item => Number.isFinite(item.distance))
    .reduce((nearest, item) => {
      if (!nearest) return item
      return item.distance < nearest.distance ? item : nearest
    }, null)
}

function formatValue(value) {
  return Number.isFinite(value) ? value.toLocaleString(undefined, {maximumFractionDigits: 3}) : String(value)
}

function formatTimestamp(date) {
  return d3.utcFormat("%Y-%m-%d %H:%M:%S UTC")(date)
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;")
}
