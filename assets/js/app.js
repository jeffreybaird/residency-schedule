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

