// Public LiveView loading events end after DOM updates, before browser paint.
// Only fixed view/operation labels and elapsed milliseconds leave the browser.
export function createBrowserLatencyReporter({window, document, performance, fetch, csrfToken}) {
  const maximumDuration = 60000
  const pending = new Set()
  const details = new WeakMap()
  const hookGenerations = new WeakMap()
  let active = true
  let pageLoadReported = false

  const clock = () => {
    try { return typeof performance?.now === "function" ? performance.now() : null }
    catch { return null }
  }
  const validDuration = duration => Number.isFinite(duration) && duration >= 0 && duration <= maximumDuration
  const validView = view => view === "calendar" || view === "schedule"
  const viewForURL = to => {
    try {
      const url = new URL(to, window.location.href)
      if (url.origin !== window.location.origin) return null
      if (url.pathname === "/" || url.pathname === "/calendar") return "calendar"
      return url.pathname === "/schedule" ? "schedule" : null
    } catch { return null }
  }
  const pageLoadView = viewForURL(window.location.href)
  const discard = record => {
    pending.delete(record)
    if (record.detail) details.delete(record.detail)
  }
  const prune = now => {
    for (const record of pending) {
      if (!validDuration(now - record.started)) discard(record)
    }
  }
  const begin = (view, operation, extra = {}) => {
    const started = clock()
    if (!active || !validView(view) || !Number.isFinite(started)) return null
    prune(started)
    if (pending.size >= 64) return null
    const record = {view, operation, started, ...extra}
    pending.add(record)
    return record
  }
  const report = (view, operation, duration_ms) => {
    if (!active || !validDuration(duration_ms)) return
    try {
      Promise.resolve(fetch("/observability/browser-latency", {
        method: "POST",
        credentials: "same-origin",
        headers: {"content-type": "application/json", accept: "text/html", "x-csrf-token": csrfToken},
        body: JSON.stringify({view, operation, duration_ms}),
      })).catch(() => {})
    } catch { /* Best effort transport must not interfere with the interface. */ }
  }
  const complete = record => {
    if (!record || !pending.has(record)) return
    discard(record)
    const ended = clock()
    if (Number.isFinite(ended)) report(record.view, record.operation, ended - record.started)
  }
  const clear = () => {
    for (const record of pending) discard(record)
  }
  const start = detail => {
    if (!detail || typeof detail !== "object") return
    if (detail.kind === "error") { clear(); return }
    if (details.has(detail)) return
    let view, operation
    if (detail.kind === "element") {
      view = detail.target?.closest?.("[data-latency-view]")?.dataset?.latencyView
      operation = "event"
    } else {
      operation = detail.kind === "initial" ? "initial" :
        detail.kind === "patch" ? "patch" : detail.kind === "redirect" ? "navigate" : null
      if (!operation || typeof detail.to !== "string") return
      view = viewForURL(detail.to)
    }
    const record = begin(view, operation, {detail})
    if (record) details.set(detail, record)
  }
  const stop = detail => {
    if (detail && typeof detail === "object") complete(details.get(detail))
  }
  const cancelHook = hook => {
    hookGenerations.set(hook, (hookGenerations.get(hook) || 0) + 1)
    for (const record of pending) if (record.hook === hook) discard(record)
  }
  const measureHookEvent = (hook, view, event, params, onReply) => {
    const generation = hookGenerations.get(hook) || 0
    const record = begin(view, "event", {hook})
    let replied = false
    return hook.pushEvent(event, params, reply => {
      if (replied) return
      replied = true
      if ((hookGenerations.get(hook) || 0) !== generation || hook.el?.isConnected === false) {
        if (record) discard(record)
        return
      }
      complete(record)
      onReply?.(reply)
    })
  }
  const reportPageLoad = () => {
    if (!active || pageLoadReported || document.readyState !== "complete") return
    const view = pageLoadView
    if (!validView(view)) return
    try {
      const entry = performance?.getEntriesByType?.("navigation")?.[0]
      if (!entry || !(entry.loadEventEnd > 0) || !validDuration(entry.duration) || entry.duration <= 0) return
      pageLoadReported = true
      report(view, "page_load", entry.duration)
    } catch { /* Navigation Timing may be unavailable. */ }
  }
  const destroy = () => { clear(); active = false }
  return {start, stop, measureHookEvent, reportPageLoad, clear, destroy, cancelHook}
}
