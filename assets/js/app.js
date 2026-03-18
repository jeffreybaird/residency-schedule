// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"

// YearTracker: updates a DOM element with the calendar year of the leftmost
// visible data column in the Gantt scroll container as the user scrolls.
const Hooks = {}

Hooks.ScrollToToday = {
  mounted() {
    this.updateTableHeight()
    this.scrollToToday()
    const stickyEl = document.getElementById("sticky-stats")
    if (stickyEl) {
      this._statsObserver = new ResizeObserver(() => this.updateTableHeight())
      this._statsObserver.observe(stickyEl)
    }
    this._resizeHandler = () => this.updateTableHeight()
    window.addEventListener("resize", this._resizeHandler)
    this._scrollHandler = () => this.updateHeaderSticky()
    this.el.addEventListener("scroll", this._scrollHandler, {passive: true})
  },
  updated() {
    this.updateTableHeight()
    this.scrollToToday()
  },
  destroyed() {
    if (this._statsObserver) this._statsObserver.disconnect()
    if (this._resizeHandler) window.removeEventListener("resize", this._resizeHandler)
    if (this._scrollHandler) this.el.removeEventListener("scroll", this._scrollHandler)
  },
  stickyOffset() {
    const navEl = document.querySelector("nav")
    const stickyEl = document.getElementById("sticky-stats")
    return (navEl ? navEl.offsetHeight : 0) + (stickyEl ? stickyEl.offsetHeight : 0)
  },
  updateTableHeight() {
    const offset = this.stickyOffset()
    this.el.style.maxHeight = (window.innerHeight - offset - 40) + "px"
  },
  updateHeaderSticky() {
    const thead = this.el.querySelector("thead")
    if (!thead) return
    const firstRow = this.el.querySelector("tbody tr")
    if (!firstRow) return
    const rowHeight = firstRow.offsetHeight
    const remaining = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight
    if (remaining < rowHeight) {
      thead.style.position = "relative"
      thead.style.top = ""
    } else {
      thead.style.position = "sticky"
      thead.style.top = "0px"
    }
  },
  scrollToToday() {
    const anchor = this.el.querySelector("[data-today-anchor]")
    if (!anchor) return
    const thead = this.el.querySelector("thead")
    const theadHeight = thead ? thead.offsetHeight : 0
    const containerRect = this.el.getBoundingClientRect()
    const anchorRect = anchor.getBoundingClientRect()
    this.el.scrollTop += anchorRect.top - containerRect.top - theadHeight - 8
  }
}

Hooks.YearTracker = {
  mounted() {
    this.yearEl = document.getElementById("gantt-year-indicator")
    this.updateYear()
    this.scrollToToday()
    this.el.addEventListener("scroll", () => this.updateYear(), {passive: true})
  },

  updated() {
    this.updateYear()
  },

  scrollToToday() {
    const todayTh = this.el.querySelector("th[data-today-slot]")
    if (!todayTh) return
    const containerRect = this.el.getBoundingClientRect()
    const thRect = todayTh.getBoundingClientRect()
    const stickyWidth = 72 + 128 // @id_col_px + @name_col_px
    this.el.scrollLeft += thRect.left - containerRect.left - stickyWidth - 8
  },

  updateYear() {
    if (!this.yearEl) return
    const containerRect = this.el.getBoundingClientRect()
    // Offset past the two sticky label columns (id + name); must match @id_col_px + @name_col_px
    const firstDataX = containerRect.left + 72 + 128

    const headers = this.el.querySelectorAll("th[data-slot-year]")
    for (const th of headers) {
      if (th.getBoundingClientRect().right > firstDataX) {
        this.yearEl.textContent = th.dataset.slotYear
        return
      }
    }
  }
}

// ResidentDrag: HTML5 drag-and-drop for moving resident names within a year group.
// Attached to each name <td>. The input inside stays editable — drag only
// starts when mousedown occurs on the cell itself (not inside the input).
// Cells in between the source and current target shift in real time to preview the move.

// Scan all name inputs in the builder and apply/remove duplicate-name error styling
// instantly on every keystroke. The server still computes the authoritative
// duplicate_name_indices on blur, but this provides immediate client-side feedback.
function checkAllDuplicateNames() {
  const inputs = Array.from(document.querySelectorAll("[data-res-year] input[type='text']"))
  const counts = {}
  inputs.forEach(inp => {
    const val = inp.value.trim().toLowerCase()
    if (val) counts[val] = (counts[val] || 0) + 1
  })
  inputs.forEach(inp => {
    const isDup = counts[inp.value.trim().toLowerCase()] > 1
    if (isDup) {
      inp.classList.add("border-red-400", "text-red-700")
      inp.classList.remove("border-transparent", "text-gray-700", "hover:border-gray-300", "focus:border-blue-400")
      inp.setAttribute("title", "Name must be unique")
    } else {
      inp.classList.remove("border-red-400", "text-red-700")
      inp.classList.add("border-transparent", "text-gray-700", "hover:border-gray-300", "focus:border-blue-400")
      inp.removeAttribute("title")
    }
  })
}

function residentDragYearCells(year) {
  return Array.from(document.querySelectorAll(`[data-res-year="${year}"]`))
    .sort((a, b) => parseInt(a.dataset.resIdx) - parseInt(b.dataset.resIdx))
}

// Transform the .name-cell-inner div (NOT the <td>) so the <td> keeps its hit-test
// area fixed — prevents the feedback loop that causes shaking.
//
// Each inner div has bg-white so it carries its own background when transformed.
// During drag we set td backgrounds transparent so a shifted inner from the cell
// above can show through without being covered by the td's own white background.

function residentDragApplyPreview(srcEl, targetEl) {
  const year = srcEl.dataset.resYear
  const cells = residentDragYearCells(year)
  const srcPos = cells.indexOf(srcEl)
  const targetPos = cells.indexOf(targetEl)
  const cellHeight = srcEl.offsetHeight
  const hasError = srcEl.dataset.hasError === "true"
  const ringColor = hasError ? "ring-red-400" : "ring-blue-400"
  const bgColor   = hasError ? "bg-red-50"   : "bg-blue-50"

  cells.forEach((cell, i) => {
    const inner = cell.querySelector(".name-cell-inner")

    let shift = ""
    if (srcPos < targetPos && i > srcPos && i <= targetPos) {
      shift = `translateY(-${cellHeight}px)`
    } else if (srcPos > targetPos && i >= targetPos && i < srcPos) {
      shift = `translateY(${cellHeight}px)`
    }

    if (inner && cell !== srcEl) {
      inner.style.transition = "transform 140ms ease"
      inner.style.transform = shift
    }

    // Target highlight: color reflects whether dragged cell has an error
    const isTarget = cell === targetEl
    cell.classList.toggle("ring-2", isTarget)
    cell.classList.toggle(ringColor, isTarget)
    cell.classList.toggle(bgColor, isTarget)
  })
}

function residentDragClearPreview() {
  const src = window._residentDragSrc
  document.querySelectorAll("[data-res-year]").forEach(cell => {
    const inner = cell.querySelector(".name-cell-inner")
    if (inner && cell !== src) {
      inner.style.transition = "none"
      inner.style.transform = ""
    }
    cell.classList.remove("ring-2", "ring-blue-400", "ring-red-400", "bg-blue-50", "bg-red-50")
    cell.removeAttribute("data-name-drag-over")
  })
}

function residentDragSetYearTransparent(year) {
  residentDragYearCells(year).forEach(cell => { cell.style.background = "transparent" })
}

function residentDragRestoreYearBackground(year) {
  residentDragYearCells(year).forEach(cell => { cell.style.background = "" })
}

Hooks.ResidentDrag = {
  mounted() {
    const el = this.el
    const input = el.querySelector("input")

    if (input) {
      input.addEventListener("mousedown", e => e.stopPropagation())
      input.addEventListener("input", checkAllDuplicateNames)
    }

    el.addEventListener("dragstart", e => {
      e.dataTransfer.effectAllowed = "move"
      e.dataTransfer.setData("text/plain", el.dataset.resIdx + ":" + el.dataset.resYear)

      const hasError = el.dataset.hasError === "true"
      const ghost = document.createElement("div")
      ghost.textContent = (input && input.value) || "—"
      ghost.style.cssText = `position:fixed;top:-100px;padding:4px 10px;background:${hasError ? "#dc2626" : "#1d4ed8"};color:white;border-radius:999px;font-size:12px;font-weight:500;white-space:nowrap;box-shadow:0 2px 8px rgba(0,0,0,.3)`
      document.body.appendChild(ghost)
      e.dataTransfer.setDragImage(ghost, ghost.offsetWidth / 2, 14)
      setTimeout(() => document.body.removeChild(ghost), 0)

      // Hide source content so its slot appears empty; make all td backgrounds
      // transparent so shifted inners from other cells can show through.
      const srcInner = el.querySelector(".name-cell-inner")
      if (srcInner) srcInner.style.opacity = "0"
      residentDragSetYearTransparent(el.dataset.resYear)

      window._residentDragSrc = el
      window._residentDragOver = null
    })

    el.addEventListener("dragend", () => {
      // Restore source inner and all td backgrounds before LiveView re-renders.
      const srcInner = el.querySelector(".name-cell-inner")
      if (srcInner) {
        srcInner.style.opacity = ""
        srcInner.style.transform = ""
        srcInner.style.transition = "none"
      }
      residentDragRestoreYearBackground(el.dataset.resYear)
      residentDragClearPreview()
      window._residentDragSrc = null
      window._residentDragOver = null
    })

    el.addEventListener("dragover", e => {
      e.preventDefault()
      e.dataTransfer.dropEffect = "move"
      const src = window._residentDragSrc
      if (!src || src === el) return
      if (src.dataset.resYear !== el.dataset.resYear) return
      if (window._residentDragOver !== el) {
        window._residentDragOver = el
        residentDragApplyPreview(src, el)
      }
    })

    el.addEventListener("dragleave", e => {
      if (!el.contains(e.relatedTarget)) {
        const nextYear = e.relatedTarget && e.relatedTarget.closest("[data-res-year]")?.dataset.resYear
        if (nextYear !== el.dataset.resYear) {
          residentDragClearPreview()
          window._residentDragOver = null
        }
      }
    })

    el.addEventListener("drop", e => {
      e.preventDefault()

      const raw = e.dataTransfer.getData("text/plain")
      const [fromIdx, fromYear] = raw.split(":")
      const toIdx = el.dataset.resIdx
      const toYear = el.dataset.resYear

      if (fromIdx === toIdx) return
      if (fromYear !== toYear) return

      this.pushEvent("swap_residents", { from_idx: fromIdx, to_idx: toIdx })
    })
  }
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...Hooks},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

