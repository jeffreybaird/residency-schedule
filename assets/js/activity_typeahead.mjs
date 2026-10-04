// Keyboard behavior for the server-owned activity suggestion list.
export default {
  mounted() {
    this._activityKeydown = event => {
      if (event.isComposing) return

      const expanded = this.el.getAttribute("aria-expanded") === "true"
      const active = this.el.getAttribute("aria-activedescendant")
      const navigates = event.key === "ArrowDown" || event.key === "ArrowUp"
      const selects = event.key === "Enter" && expanded && active
      const closes = event.key === "Escape" && expanded

      if (navigates || selects || closes) {
        event.preventDefault()
        this.pushEvent("suggestion-key", {key: event.key})
      }
    }
    this.el.addEventListener("keydown", this._activityKeydown)
    this._activityWrapper = this.el.closest?.("[data-activity-typeahead]")
    this._activityPointerdown = event => {
      const option = event.target.closest?.('[role="option"]')
      if (option && this._activityWrapper.contains(option)) event.preventDefault()
    }
    this._activityWrapper?.addEventListener("pointerdown", this._activityPointerdown)
    this.handleEvent("activity-query-selected", ({query}) => {
      this.el.value = query
      this.el.focus()
    })
  },
  destroyed() {
    this.el.removeEventListener("keydown", this._activityKeydown)
    this._activityWrapper?.removeEventListener("pointerdown", this._activityPointerdown)
  },
}
