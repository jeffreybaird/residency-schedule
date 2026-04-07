import Shepherd from "../vendor/shepherd.js"

// Default button config shared across steps
const defaultButtons = {
  back: { text: "Back", action: "back", classes: "shepherd-button-secondary" },
  next: { text: "Next", action: "next" },
  done: { text: "Got it!", action: "complete" }
}

// Tour step definitions — edit this array to change the walkthrough content.
// Each step is { id, attachTo: { element, on }, title, text, buttons }.
// `element` is a CSS selector; `on` is a Floating UI placement (bottom, top, left, right).
const STEPS = [
  {
    id: "welcome",
    title: "Welcome to URMC OBGYN Scheduling!",
    text: "Let\u2019s take a quick look around so you know where everything is. This will only take a minute.",
    buttons: ["next"]
  },
  {
    id: "schedule-pills",
    attachTo: { element: "#tour-schedule-pills", on: "bottom" },
    title: "Academic Year Schedules",
    text: "Each pill represents an academic year. All schedules are shown in one continuous timeline \u2014 scroll right to move through them. You can also click a pill to jump to that year.",
    buttons: ["back", "next"]
  },
  {
    id: "year-filter",
    attachTo: { element: "#tour-year-filter", on: "bottom" },
    title: "Filter by Residency Year",
    text: "Use these buttons to show only residents from a specific year (R1, R2, R3, or R4), or click \u201CAll\u201D to see everyone.",
    buttons: ["back", "next"]
  },
  {
    id: "gantt-grid",
    attachTo: { element: "#gantt-scroll", on: "top" },
    title: "The Schedule Grid",
    text: "This is the main view. Each row is a resident, and each column is a week. Scroll left and right to move through time. The grid automatically starts at today\u2019s date.",
    buttons: ["back", "next"]
  },
  {
    id: "resident-link",
    attachTo: { element: "#gantt-scroll tbody tr:not(.bg-gray-50) td:first-child a", on: "right" },
    title: "Resident Details",
    text: "Click any resident\u2019s name or ID to see their full rotation schedule, including a monthly calendar view.",
    buttons: ["back", "next"]
  },
  {
    id: "nav-calendar",
    attachTo: { element: "#tour-nav-calendar", on: "bottom" },
    title: "Calendar View",
    text: "The Calendar page shows the schedule as a traditional monthly calendar. Great for seeing who\u2019s on which rotation on a specific day.",
    buttons: ["back", "next"]
  },
  {
    id: "nav-compare",
    attachTo: { element: "#tour-nav-compare", on: "bottom" },
    title: "Compare Residents",
    text: "Use Compare to view two or more residents side-by-side and see where their schedules overlap.",
    buttons: ["back", "done"]
  }
]

/**
 * Creates and returns a configured Shepherd tour instance.
 * Call `tour.start()` to begin and listen for "complete"/"cancel" to persist.
 */
export function createTour() {
  const tour = new Shepherd.Tour({
    useModalOverlay: true,
    defaultStepOptions: {
      cancelIcon: { enabled: true },
      scrollTo: { behavior: "smooth", block: "center" }
    }
  })

  for (const step of STEPS) {
    const buttons = (step.buttons || ["next"]).map(key => {
      if (key === "next") return { text: defaultButtons.next.text, action: () => tour.next(), classes: "shepherd-button" }
      if (key === "back") return { text: defaultButtons.back.text, action: () => tour.back(), classes: "shepherd-button shepherd-button-secondary" }
      if (key === "done") return { text: defaultButtons.done.text, action: () => tour.complete(), classes: "shepherd-button" }
      return key
    })

    tour.addStep({
      id: step.id,
      title: step.title,
      text: step.text,
      attachTo: step.attachTo,
      buttons
    })
  }

  return tour
}
