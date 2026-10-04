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
import {buildTour, consumeTourState} from "./tour.js"
import ActivityTypeahead from "./activity_typeahead.mjs"

// YearTracker: updates a DOM element with the calendar year of the leftmost
// visible data column in the Gantt scroll container as the user scrolls.
const Hooks = {}
Hooks.ActivityTypeahead = ActivityTypeahead

// ChatScroll: keeps the assistant log pinned to its newest line as text
// streams in, unless the user has scrolled up to read something earlier.
Hooks.ChatScroll = {
  mounted() { this.el.scrollTop = this.el.scrollHeight },
  updated() {
    const nearBottom = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 80
    if (nearBottom) this.el.scrollTop = this.el.scrollHeight
  },
}

// Key recording that a demo visitor has already seen the walkthrough. The demo
// user is unpersisted and shared by every visitor, so the server cannot track
// this the way it does for a real account — it always offers the tour and the
// browser decides whether to show it.
const DEMO_TOUR_SEEN = "demo_tour_seen"

// GuidedTour: launches the Shepherd walkthrough on first login or when
// the user clicks "Take a tour". Resumes across page navigations via sessionStorage.
Hooks.GuidedTour = {
  mounted() {
    this._page = this.el.dataset.tourPage || "schedule"
    this._role = this.el.dataset.tourRole || "user"
    // Read from the layout, not this element: the tour ends on /compare, and a
    // per-page attribute that only the calendar carried left the "seen" flag
    // unwritten there, restarting the tour on the redirect home.
    this._demo = document.querySelector('meta[name="demo-mode"]')?.content === "true"
    this._startTour = () => this._run(this._page)

    // Check if we're resuming after a page navigation.
    // consumeTourState() reads AND clears sessionStorage so it only fires once.
    const saved = consumeTourState()
    if (saved && saved.resume === this._page) {
      // Resuming takes priority — never also auto-start
      setTimeout(() => this._run(this._page, saved.startAt), 500)
    } else if (this.el.dataset.autoStart === "true" && !this._demoTourSeen()) {
      // First-time tour for a new user (no resume state in sessionStorage)
      setTimeout(() => this._run(this._page), 500)
    }

    // Listen for manual re-trigger from "Take a tour" link
    window.addEventListener("start-tour", this._startTour)

    // Listen for server-pushed re-trigger
    this.handleEvent("start-tour", () => this._run(this._page))
  },

  // Live navigation can replace the page under an open tour (browser back or
  // forward while a step is showing). Shepherd's overlay lives outside the
  // LiveView, so it is closed here, and nothing is pushed to a view that is
  // already gone.
  destroyed() {
    window.removeEventListener("start-tour", this._startTour)
    this._gone = true
    if (this._tour && this._tour.isActive()) this._tour.cancel()
  },

  // localStorage can throw or be unavailable (private mode, blocked cookies).
  // Failing to read means "not seen", so the tour still runs.
  _demoTourSeen() {
    if (!this._demo) return false

    try {
      return localStorage.getItem(DEMO_TOUR_SEEN) === "true"
    } catch (_e) {
      return false
    }
  },

  _markDemoTourSeen() {
    if (!this._demo) return

    try {
      localStorage.setItem(DEMO_TOUR_SEEN, "true")
    } catch (_e) {
      // Nothing to do — the tour will simply show again next visit.
    }
  },

  // Server-rendered so demo and production tours never diverge from the nav.
  _brand() {
    return document.querySelector('meta[name="brand-name"]')?.content || "Residency Schedule"
  },

  _run(page, startAtId) {
    const tour = buildTour(page, startAtId, this._role, this._brand())
    this._tour = tour
    tour.on("complete", () => {
      this._markDemoTourSeen()
      if (!this._gone) this.pushEvent("tour_completed", {})
    })
    tour.on("cancel", () => {
      // Navigation cancels save state before calling cancel — don't mark complete
      if (!sessionStorage.getItem("guided_tour_state")) {
        this._markDemoTourSeen()
        if (!this._gone) this.pushEvent("tour_completed", {})
      }
    })
    tour.start()
  }
}

// CalendarPrefs: persists the calendar's view mode, resident/rotation filters and
// open filter panel in localStorage so they survive a page refresh or navigating
// away and back. On mount it replays the saved prefs to the server; thereafter the
// server pushes "save_calendar_prefs" whenever they change.
Hooks.CalendarPrefs = {
  STORAGE_KEY: "calendar_prefs",

  mounted() {
    const saved = this.read()
    if (saved) this.pushEvent("restore_prefs", saved)
    this.handleEvent("save_calendar_prefs", prefs => this.write(prefs))
  },

  read() {
    try {
      const raw = localStorage.getItem(this.STORAGE_KEY)
      return raw ? JSON.parse(raw) : null
    } catch {
      return null
    }
  },

  write(prefs) {
    try {
      localStorage.setItem(this.STORAGE_KEY, JSON.stringify(prefs))
    } catch {
      // localStorage may be unavailable (private mode, quota) — prefs just won't persist.
    }
  }
}

// CalendarSwipe: on touch devices, a horizontal swipe across the calendar body
// moves to the next/previous period. The LiveView's "prev"/"next" events are
// already view-aware (day/week/month), so the hook just pushes them.
Hooks.CalendarSwipe = {
  mounted() {
    this.startX = null
    this.startY = null

    // Minimum horizontal travel (px) and max vertical drift to count as a swipe.
    const THRESHOLD = 50
    const MAX_VERTICAL_RATIO = 0.75

    this._onTouchStart = (e) => {
      if (e.touches.length !== 1) {
        this.startX = null
        return
      }
      this.startX = e.touches[0].clientX
      this.startY = e.touches[0].clientY
    }

    this._onTouchEnd = (e) => {
      if (this.startX === null) return
      const touch = e.changedTouches[0]
      const dx = touch.clientX - this.startX
      const dy = touch.clientY - this.startY
      this.startX = null
      this.startY = null

      if (Math.abs(dx) < THRESHOLD) return
      if (Math.abs(dy) > Math.abs(dx) * MAX_VERTICAL_RATIO) return

      // Swipe left → forward (next); swipe right → backward (prev).
      this.pushEvent(dx < 0 ? "next" : "prev", {})
    }

    this.el.addEventListener("touchstart", this._onTouchStart, {passive: true})
    this.el.addEventListener("touchend", this._onTouchEnd, {passive: true})
  },

  destroyed() {
    this.el.removeEventListener("touchstart", this._onTouchStart)
    this.el.removeEventListener("touchend", this._onTouchEnd)
  }
}

// Positions #service-filter-panel with fixed coordinates under #service-filter-toggle so the
// menu is not clipped by #rotation-table-scroll (overflow-auto).
Hooks.ServiceFilterAnchored = {
  mounted() {
    this._position = () => this.positionPanel()
    this.scheduleAlignPanel = () => {
      queueMicrotask(() => {
        requestAnimationFrame(() => {
          requestAnimationFrame(() => this.positionPanel())
        })
      })
    }
    this._docClick = e => {
      const panel = document.getElementById("service-filter-panel")
      const toggle = document.getElementById("service-filter-toggle")
      if (!panel) return
      if ((toggle && toggle.contains(e.target)) || panel.contains(e.target)) return
      this.pushEvent("close_service_filter_menu", {})
    }
    document.addEventListener("click", this._docClick, true)
    // After LiveView patches DOM, hook updated() runs *after* phx:update; defer past ScrollToToday et al.
    this._phxUpdate = () => this.scheduleAlignPanel()
    document.addEventListener("phx:update", this._phxUpdate)
    this._position()
    window.addEventListener("resize", this._position)
    // Panel is position:fixed to the toggle’s viewport rect — main-page scroll must recompute it
    // (scroll inside #rotation-table-scroll does not bubble to window).
    window.addEventListener("scroll", this._position, {passive: true})
    this._scrollEl = this.el.querySelector("#rotation-table-scroll")
    if (this._scrollEl) {
      this._scrollEl.addEventListener("scroll", this._position, {passive: true})
      this._scrollRo = new ResizeObserver(() => this._position())
      this._scrollRo.observe(this._scrollEl)
    }
    this._statsEl = document.getElementById("sticky-stats")
    if (this._statsEl) {
      this._statsRo = new ResizeObserver(() => this._position())
      this._statsRo.observe(this._statsEl)
    }
  },
  updated() {
    this.scheduleAlignPanel()
  },
  destroyed() {
    document.removeEventListener("click", this._docClick, true)
    document.removeEventListener("phx:update", this._phxUpdate)
    window.removeEventListener("resize", this._position)
    window.removeEventListener("scroll", this._position, {passive: true})
    if (this._scrollEl) {
      this._scrollEl.removeEventListener("scroll", this._position)
    }
    if (this._scrollRo) this._scrollRo.disconnect()
    if (this._statsRo) this._statsRo.disconnect()
  },
  positionPanel() {
    const toggle = document.getElementById("service-filter-toggle")
    const panel = document.getElementById("service-filter-panel")
    if (!toggle || !panel) return
    const btn = toggle.getBoundingClientRect()
    const margin = 6
    panel.style.position = "fixed"
    panel.style.top = `${btn.bottom + margin}px`
    panel.style.right = `${Math.max(8, window.innerWidth - btn.right)}px`
    panel.style.left = "auto"
    panel.style.bottom = "auto"
    panel.style.zIndex = "60"
  }
}

Hooks.ScrollToToday = {
  mounted() {
    this.updateTableHeight()
    this.scrollToToday()
    this._lastAnchorId = this.currentAnchorId()
    this.updateHeaderSticky()
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
  beforeUpdate() {
    // morphdom re-renders the table body on every patch (e.g. opening the
    // coworkers modal), which drops the scroll container's offset. Capture it
    // here so updated() can restore it.
    this._savedScrollTop = this.el.scrollTop
  },
  updated() {
    this.updateTableHeight()
    // Re-anchor to today only when the table content actually changed (e.g. a
    // service filter swaps the rows). Patches that leave the rows untouched —
    // opening the coworkers modal, toggling stats — must keep the user where
    // they were, so restore the pre-patch scroll instead.
    const anchorId = this.currentAnchorId()
    if (anchorId !== this._lastAnchorId) {
      this._lastAnchorId = anchorId
      this.scrollToToday()
    } else if (this._savedScrollTop != null) {
      this.el.scrollTop = this._savedScrollTop
    }
    this.updateHeaderSticky()
  },
  currentAnchorId() {
    const anchor = this.el.querySelector("[data-today-anchor]")
    return anchor ? anchor.id : null
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
    // Toggling thead between sticky and relative reflows the table and can jump scroll
    // (including the main window with scroll anchoring). Skip while the service filter is open.
    if (document.getElementById("service-filter-panel")) return
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
    if (document.getElementById("service-filter-panel")) return
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
    this._lastAcaYear = null
    this._acaYearTimer = null
    this.yearEl = document.getElementById("gantt-year-indicator")
    this.stickyWidth = 148 // @name_col_px (ID column removed)
    this.updateYear()
    this.updateActivePill()
    this.scrollToToday()
    this.updateCohortVisibility()
    this.el.addEventListener("scroll", () => {
      this.updateYear()
      this.updateActivePill()
      this.updateCohortVisibility()
      this._pushAcaYearChange()
    }, {passive: true})

    // Listen for scroll-to-schedule events from LiveView
    this.handleEvent("scroll-to-schedule", ({schedule_id}) => {
      this.scrollToSchedule(schedule_id)
    })
  },

  updated() {
    this.updateYear()
    this.updateActivePill()
    this.updateCohortVisibility()
  },

  scrollToToday() {
    const todayTh = this.el.querySelector("th[data-today-slot]")
    if (!todayTh) return
    const containerRect = this.el.getBoundingClientRect()
    const thRect = todayTh.getBoundingClientRect()
    this.el.scrollLeft += thRect.left - containerRect.left - this.stickyWidth - 8
  },

  scrollToSchedule(scheduleId) {
    const th = this.el.querySelector(`th[data-schedule-start="${scheduleId}"]`)
    if (!th) return
    const containerRect = this.el.getBoundingClientRect()
    const thRect = th.getBoundingClientRect()
    this.el.scrollLeft += thRect.left - containerRect.left - this.stickyWidth
    this.updateCohortVisibility()
  },

  _visibleAcaYear() {
    const containerRect = this.el.getBoundingClientRect()
    const firstDataX = containerRect.left + this.stickyWidth
    const headers = this.el.querySelectorAll("th[data-slot-aca-year]")
    for (const th of headers) {
      if (th.getBoundingClientRect().right > firstDataX) {
        return parseInt(th.dataset.slotAcaYear)
      }
    }
    return null
  },

  _pushAcaYearChange() {
    const acaYear = this._visibleAcaYear()
    if (acaYear === null || acaYear === this._lastAcaYear) return
    this._lastAcaYear = acaYear
    clearTimeout(this._acaYearTimer)
    this._acaYearTimer = setTimeout(() => {
      this.pushEvent("view_academic_year", {aca_year: acaYear})
    }, 300)
  },

  updateYear() {
    if (!this.yearEl) return
    const containerRect = this.el.getBoundingClientRect()
    const firstDataX = containerRect.left + this.stickyWidth

    const headers = this.el.querySelectorAll("th[data-slot-year]")
    for (const th of headers) {
      if (th.getBoundingClientRect().right > firstDataX) {
        this.yearEl.textContent = th.dataset.slotYear
        return
      }
    }
  },

  updateActivePill() {
    const containerRect = this.el.getBoundingClientRect()
    const firstDataX = containerRect.left + this.stickyWidth
    let activeId = null

    // Find which schedule's columns are currently visible
    const headers = this.el.querySelectorAll("th[data-schedule-id]")
    for (const th of headers) {
      if (th.getBoundingClientRect().right > firstDataX) {
        activeId = th.dataset.scheduleId
        break
      }
    }

    // Update pill styles
    const pills = document.querySelectorAll("[data-schedule-pill]")
    pills.forEach(pill => {
      const isActive = pill.dataset.schedulePill === activeId
      pill.classList.toggle("bg-blue-600", isActive)
      pill.classList.toggle("text-white", isActive)
      pill.classList.toggle("bg-gray-100", !isActive)
      pill.classList.toggle("text-gray-700", !isActive)
      pill.classList.toggle("dark:bg-gray-800", !isActive)
      pill.classList.toggle("dark:text-gray-200", !isActive)
    })
  },

  _visibleAcaYearRange() {
    const containerRect = this.el.getBoundingClientRect()
    const firstDataX = containerRect.left + this.stickyWidth
    const rightEdge = containerRect.right
    const headers = this.el.querySelectorAll("th[data-slot-aca-year]")
    let min = null
    let max = null
    for (const th of headers) {
      const rect = th.getBoundingClientRect()
      if (rect.right < firstDataX) continue
      if (rect.left > rightEdge) break
      const year = parseInt(th.dataset.slotAcaYear)
      if (min === null || year < min) min = year
      if (max === null || year > max) max = year
    }
    return { min, max }
  },

  updateCohortVisibility() {
    const { min: minAcaYear, max: maxAcaYear } = this._visibleAcaYearRange()
    if (minAcaYear === null) return
    const minGrad = minAcaYear
    const maxGrad = maxAcaYear + 3
    const rows = this.el.querySelectorAll("tr[data-cohort-graduation-year]")
    rows.forEach(row => {
      const gradYear = parseInt(row.dataset.cohortGraduationYear)
      row.classList.toggle("hidden", gradYear < minGrad || gradYear > maxGrad)
    })
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
      inp.classList.add("border-red-400", "text-red-700", "dark:text-red-300")
      inp.classList.remove("border-transparent", "text-gray-700", "dark:text-gray-200", "hover:border-gray-300", "dark:hover:border-gray-600", "focus:border-blue-400")
      inp.setAttribute("title", "Name must be unique")
    } else {
      inp.classList.remove("border-red-400", "text-red-700", "dark:text-red-300")
      inp.classList.add("border-transparent", "text-gray-700", "dark:text-gray-200", "hover:border-gray-300", "dark:hover:border-gray-600", "focus:border-blue-400")
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
// Each inner div carries its themed background when transformed.
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
  const darkBgColor = hasError ? "dark:bg-red-950" : "dark:bg-blue-950"

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
    cell.classList.toggle(darkBgColor, isTarget)
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
    cell.classList.remove("ring-2", "ring-blue-400", "ring-red-400", "bg-blue-50", "bg-red-50", "dark:bg-blue-950", "dark:bg-red-950")
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

// The nav in the root layout is outside every LiveView, so live navigation
// leaves it as it was rendered. Mark the home-resident link current only on
// its own page, and fold the mobile menu the user just picked from.
const syncNav = () => {
  document.querySelectorAll("[data-nav-home]").forEach(link => {
    if (link.getAttribute("href") === window.location.pathname) {
      link.setAttribute("aria-current", "page")
    } else {
      link.removeAttribute("aria-current")
    }
  })
  document.getElementById("mobile-nav")?.removeAttribute("open")
}
window.addEventListener("phx:navigate", syncNav)

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
