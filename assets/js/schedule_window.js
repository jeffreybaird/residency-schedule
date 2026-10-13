// Fixed slot geometry keeps scroll position independent of materialized cells.
const SLOT_WIDTH = 80
const NAME_WIDTH = 148
const BUFFER = 8
const MAX_COLUMNS = 128

export function desiredWindow(scrollLeft, clientWidth, total) {
  if (total <= 0) return {start: 0, count: 0, first: 0}
  const first = Math.max(0, Math.min(total - 1, Math.floor(scrollLeft / SLOT_WIDTH)))
  const visible = Math.ceil(Math.max(clientWidth - NAME_WIDTH, 0) / SLOT_WIDTH) + 1
  const count = Math.min(total, MAX_COLUMNS, visible + BUFFER * 2)
  const start = Math.min(Math.max(first - BUFFER, 0), total - count)
  return {start, count, first}
}

export function createScheduleWindowHook(browserLatency) {
  return {
    mounted() {
      this._generation = 0
      this._eventRefs = []
      this.readMetadata()
      this._eventRefs.push(this.handleEvent("scroll-to-schedule", ({schedule_id}) => {
        const index = this._slots.findIndex(slot => String(slot[2]) === String(schedule_id))
        if (index >= 0) this.moveTo(index * SLOT_WIDTH)
      }))
      this._eventRefs.push(this.handleEvent("restore-schedule-focus", ({cell_id, index}) => {
        const left = this._modalScrollLeft ?? index * SLOT_WIDTH
        this._modalScrollLeft = null
        this._focusPending = {cellId: cell_id, index}
        this.moveTo(left)
      }))
      this.connect()
      const today = Number(this.el.dataset.todayIndex)
      if (today >= 0 && today < this._slots.length) this.moveTo(today * SLOT_WIDTH)
    },

    beforeUpdate() { this._savedScrollLeft = this.el.scrollLeft },

    updated() {
      if (this._savedScrollLeft != null) this.el.scrollLeft = this._savedScrollLeft
      this._savedScrollLeft = null
      this.readMetadata()
      const modalOpen = !!document.getElementById("gantt-rotation-modal")
      if (modalOpen && !this._modalOpen) this._modalScrollLeft = this.el.scrollLeft
      this._modalOpen = modalOpen
      this.scheduleFrame()
    },

    disconnected() { this.disconnect() },
    reconnected() { this.connect() },
    destroyed() {
      this.disconnect()
      for (const ref of this._eventRefs || []) this.removeHandleEvent?.(ref)
      this._eventRefs = []
    },

    connect() {
      if (this._connected) return
      this._connected = true
      this._onScroll = () => this.scheduleFrame()
      this._onResize = () => this.scheduleFrame()
      this.el.addEventListener("scroll", this._onScroll, {passive: true})
      if (typeof ResizeObserver !== "undefined") {
        this._observer = new ResizeObserver(this._onResize)
        this._observer.observe(this.el)
      } else {
        window.addEventListener("resize", this._onResize)
      }
      this.scheduleFrame()
    },

    disconnect() {
      this._connected = false
      this._generation++
      browserLatency.cancelHook(this)
      if (this._frame != null) cancelAnimationFrame(this._frame)
      this._frame = null
      this._inflight = null
      this._focusPending = null
      this._ackedYear = null
      this.el.removeEventListener("scroll", this._onScroll)
      this._observer?.disconnect()
      this._observer = null
      window.removeEventListener("resize", this._onResize)
    },

    readMetadata() {
      const metadata = this.el.dataset.slotMetadata
      if (this._metadata !== metadata) {
        this._metadata = metadata
        this._slots = JSON.parse(metadata || "[]")
        this._ackedYear = null
      }
      this.yearEl = document.getElementById("gantt-year-indicator")
    },

    moveTo(left) {
      this.el.scrollLeft = Math.max(0, left)
      this.scheduleFrame()
    },

    scheduleFrame() {
      if (!this._connected || this._frame != null) return
      this._frame = requestAnimationFrame(() => {
        this._frame = null
        if (!this._connected) return
        this.updateYear()
        this.updateActivePill()
        this.updateCohortVisibility()
        this.restoreFocus()
        this.requestWindow()
      })
    },

    visibleRange() {
      return desiredWindow(this.el.scrollLeft, this.el.clientWidth, this._slots.length)
    },

    requestWindow() {
      if (this._inflight || !this._slots.length) return
      const desired = this.visibleRange()
      const year = this._slots[desired.first][1]
      const start = Number(this.el.dataset.windowStart)
      const count = Number(this.el.dataset.windowCount)
      const finish = start + count
      // At the hard cap, avoid repeatedly asking for the same bounded range.
      if (desired.start === start && desired.count === count && year === this._ackedYear) return
      const visibleEnd = Math.min(this._slots.length,
        desired.first + Math.ceil(Math.max(this.el.clientWidth - NAME_WIDTH, 0) / SLOT_WIDTH) + 1)
      const nearLeft = start > 0 && desired.first < start + BUFFER / 2
      const nearRight = finish < this._slots.length && visibleEnd > finish - BUFFER / 2
      if (!nearLeft && !nearRight && desired.first >= start && visibleEnd <= finish && year === this._ackedYear) return
      const generation = this._generation
      this._inflight = desired
      browserLatency.measureHookEvent(this, "schedule", "update_window", desired, () => {
        if (!this._connected || generation !== this._generation) return
        this._inflight = null
        this._ackedYear = year
        this.scheduleFrame()
      })
    },

    restoreFocus() {
      if (!this._focusPending) return
      const start = Number(this.el.dataset.windowStart)
      const finish = start + Number(this.el.dataset.windowCount)
      if (this._focusPending.index < start || this._focusPending.index >= finish) return
      const target = document.getElementById(`gantt-pill-${this._focusPending.cellId}`) || this.el
      this._focusPending = null
      target.focus({preventScroll: true})
    },

    updateYear() {
      const slot = this._slots[this.visibleRange().first]
      if (this.yearEl && slot) this.yearEl.textContent = String(slot[0])
    },

    updateActivePill() {
      const slot = this._slots[this.visibleRange().first]
      const active = slot && String(slot[2])
      document.querySelectorAll("[data-schedule-pill]").forEach(pill => {
        const selected = pill.dataset.schedulePill === active
        pill.classList.toggle("bg-blue-600", selected)
        pill.classList.toggle("text-white", selected)
        pill.classList.toggle("bg-gray-100", !selected)
        pill.classList.toggle("text-gray-700", !selected)
        pill.classList.toggle("dark:bg-gray-800", !selected)
        pill.classList.toggle("dark:text-gray-200", !selected)
      })
    },

    updateCohortVisibility() {
      const first = this.visibleRange().first
      const count = Math.ceil(Math.max(this.el.clientWidth - NAME_WIDTH, 0) / SLOT_WIDTH) + 1
      const years = this._slots.slice(first, first + count).map(slot => slot[1])
      if (!years.length) return
      const min = Math.min(...years), max = Math.max(...years) + 3
      this.el.querySelectorAll("tr[data-cohort-graduation-year]").forEach(row => {
        const year = Number(row.dataset.cohortGraduationYear)
        row.classList.toggle("hidden", year < min || year > max)
      })
    }
  }
}
