import Shepherd from "../vendor/shepherd.js";

const MODAL_PADDING = 8;
const MODAL_RADIUS = 4;

// ── Step definitions ─────────────────────────────────────────────────────────

const CALENDAR_STEPS = [
  {
    id: "welcome",
    title: (_role, brand) => `Welcome to ${brand}!`,
    text: "Let\u2019s take a quick look around so you know where everything is. This will only take a minute.<br><br><em class='shepherd-tour-hint'>Click anywhere outside the tour to explore \u2014 a button will appear to continue.</em>",
    buttons: ["next"],
  },
  {
    id: "calendar-overview",
    title: "Your Calendar",
    text: (role) => {
      if (role === "resident") {
        return "This is your home page \u2014 the schedule shown as a calendar. Once you set your page as Home, it opens filtered to your own shifts.";
      }
      if (role === "user") {
        return "This is your home page \u2014 the schedule shown as a calendar. Once you follow a resident (say, your partner), it opens filtered to their shifts.";
      }
      return "This is the home page \u2014 the schedule shown as a calendar.";
    },
    buttons: ["next"],
  },
  {
    id: "calendar-views",
    attachTo: { element: "#tour-view-toggle", on: "bottom" },
    title: "Month, Week & Day",
    text: "Switch between Month, Week, and Day views here. The calendar opens on the current week by default.",
    buttons: ["back", "next"],
  },
  {
    id: "calendar-filters",
    attachTo: { element: "#tour-calendar-filters", on: "bottom" },
    title: "Filter the Calendar",
    text: (role) =>
      role === "resident"
        ? "Filter by resident or by rotation to focus on exactly what you need. Picking your own name shows just your schedule; clear it to see everyone."
        : "Filter by resident or by rotation to focus on exactly what you need. Picking one name shows just that resident’s schedule; clear it to see everyone.",
    buttons: ["back", "next"],
  },
  {
    id: "calendar-nav",
    attachTo: { element: "#tour-month-nav", on: "bottom" },
    title: "Move Through Time",
    text: "Step backward and forward \u2014 by month, week, or day depending on your view \u2014 or tap Today to jump back to now.",
    buttons: ["back", "next"],
  },
  {
    id: "calendar-grid",
    attachTo: { element: "#tour-calendar-grid", on: "top" },
    title: "See Each Day",
    text: "Click any day to see who\u2019s on each rotation. The colored labels show the different services.",
    buttons: ["back", "next"],
  },
  {
    id: "nav-schedule",
    attachTo: { element: "#tour-nav-schedule", on: "bottom" },
    title: "The Schedule Grid",
    text: "Next, let\u2019s look at the full schedule grid showing every resident across the year.",
    buttons: ["back", { key: "navigate", dest: "schedule", label: "Let\u2019s go \u2192" }],
  },
];

const SCHEDULE_STEPS = [
  {
    id: "schedule-pills",
    attachTo: { element: "#tour-schedule-pills", on: "bottom" },
    title: "Academic Year Schedules",
    text: "Each pill represents an academic year. All schedules are shown in one continuous timeline \u2014 scroll right to move through them. You can also click a pill to jump to that year.",
    buttons: ["next"],
  },
  {
    id: "year-filter",
    attachTo: { element: "#tour-year-filter", on: "bottom" },
    title: "Filter by Residency Year",
    text: "Use these buttons to show only residents from a specific year (R1, R2, R3, or R4), or click \u201CAll\u201D to see everyone.",
    buttons: ["back", "next"],
  },
  {
    id: "gantt-grid",
    attachTo: { element: "#gantt-scroll", on: "top" },
    title: "The Schedule Grid",
    text: "Each row is a resident, and each column is a week. Scroll left and right to move through time. The grid automatically starts at today\u2019s date.",
    buttons: ["back", "next"],
  },
  {
    id: "resident-name",
    attachTo: {
      element:
        "td[data-tour-resident-name][data-cohort-graduation-year='2026']",
      on: "right",
    },
    title: "Resident Names",
    text: "Clicking on a resident\u2019s name will take you to their personal schedule page.",
    buttons: ["back", "navigate-resident"],
  },
];

const RESIDENT_STEPS = [
  {
    id: "resident-overview",
    title: "Resident Detail Page",
    text: "This is a resident\u2019s personal schedule page. Everything about their year is here.",
    buttons: ["next"],
  },
  {
    id: "resident-follow",
    attachTo: { element: "#tour-follow-home", on: "bottom" },
    roles: ["resident", "user"],
    title: (role) => (role === "resident" ? "Set Your Home Page" : "Follow a Resident"),
    text: (role) =>
      role === "resident"
        ? "When you\u2019re on your own page, click <strong>Set as Home</strong>. The nav gains a <strong>My page</strong> shortcut and your calendar opens on your schedule automatically."
        : "Following a resident \u2014 say, your partner \u2014 adds a <strong>Following</strong> shortcut to the nav and opens your calendar on their schedule automatically. Click <strong>Follow</strong> on their page to set it up, and use the <strong>Download .ics</strong> link below to subscribe from your own calendar app.",
    buttons: ["back", "next"],
  },
  {
    id: "resident-stats",
    attachTo: { element: "#sticky-stats", on: "bottom" },
    title: "Schedule Stats",
    text: "At the top you\u2019ll see shift counts: total shifts, shifts remaining, and night shifts remaining at each hospital.",
    buttons: ["back", "next"],
  },
  {
    id: "resident-rotation-table",
    attachTo: { element: "#rotation-table", on: "top" },
    title: "Rotation Table",
    text: "This table lists every rotation across all of their academic years, color-coded by service. It scrolls to today automatically \u2014 keep scrolling to move into the next year. Try clicking any row \u2014 it shows who\u2019s on the same rotation that week.",
    buttons: ["back", "next"],
  },
  {
    id: "resident-coworkers",
    attachTo: { element: "tr[phx-click='open_shift_coworkers']", on: "top" },
    title: "See Coworkers",
    text: "Click any shift row like this one to see a popup with every resident on the same rotation that week. It\u2019s a quick way to find out who you\u2019re working with.",
    buttons: ["back", "next"],
  },
  {
    id: "resident-service-filter",
    attachTo: { element: "#service-filter-toggle", on: "bottom" },
    title: "Filter by Service",
    text: "Click this arrow to filter the table by rotation type \u2014 for example, show only night float or OB shifts.",
    buttons: [
      "back",
      {
        key: "navigate",
        dest: "compare",
        label: "See compare \u2192",
      },
    ],
  },
];

const COMPARE_STEPS = [
  {
    id: "compare-overview",
    title: "Compare Residents",
    text: "This page lets you see where two residents\u2019 schedules overlap \u2014 when they\u2019re on the same service at the same time.",
    buttons: ["next"],
  },
  {
    id: "compare-dropdowns",
    attachTo: { element: "#tour-compare-dropdowns", on: "bottom" },
    title: "Pick Two Residents",
    text: "Select Resident A and Resident B from the dropdowns. The page will show every week they share a rotation.",
    buttons: ["back", "next"],
  },
  {
    id: "compare-done",
    title: "That\u2019s Everything!",
    text: "You\u2019ve seen all the main features. You can restart this tour any time from the \u201CTake a tour\u201D link on the calendar (home) page.",
    buttons: ["finish-home"],
  },
];

const STEP_SETS = {
  schedule: SCHEDULE_STEPS,
  resident: RESIDENT_STEPS,
  calendar: CALENDAR_STEPS,
  compare: COMPARE_STEPS,
};

// ── Session storage ──────────────────────────────────────────────────────────

const TOUR_STATE_KEY = "guided_tour_state";

function saveTourState(state) {
  sessionStorage.setItem(TOUR_STATE_KEY, JSON.stringify(state));
}

function consumeTourState() {
  const raw = sessionStorage.getItem(TOUR_STATE_KEY);
  if (!raw) return null;
  sessionStorage.removeItem(TOUR_STATE_KEY);
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

// ── Navigation ───────────────────────────────────────────────────────────────

const PAGE_PATHS = {
  schedule: "/schedule",
  calendar: "/",
  compare: "/compare",
};

function navigateToPage(dest, startAt, tour) {
  saveTourState({ resume: dest, startAt: startAt || null });
  tour.cancel();
  window.location.href = PAGE_PATHS[dest] || "/";
}

// ── Pause / Resume ───────────────────────────────────────────────────────────

function setupPauseResume(tour) {
  // Create the floating "Continue Tour" button
  const btn = document.createElement("button");
  btn.id = "tour-continue-btn";
  btn.textContent = "Continue Tour";
  btn.style.display = "none";
  document.body.appendChild(btn);

  let paused = false;
  const PAUSE_CLASS = "tour-paused";

  function pauseTour() {
    if (paused) return;
    paused = true;
    document.body.classList.add(PAUSE_CLASS);
    btn.style.display = "";
  }

  function resumeTour() {
    if (!paused) return;
    paused = false;
    document.body.classList.remove(PAUSE_CLASS);
    btn.style.display = "none";
  }

  // Click the continue button to resume
  btn.addEventListener("click", () => {
    resumeTour();
  });

  // Pause the tour when the user clicks anywhere outside the tooltip.
  // This covers both the overlay (dark area) and the highlighted element
  // (the cutout hole in the overlay where clicks pass through to the page).
  const interceptClick = (e) => {
    if (paused) return;

    // Don't pause if clicking inside the tooltip itself
    const tooltip = document.querySelector(".shepherd-element");
    if (tooltip && tooltip.contains(e.target)) return;

    // Don't pause if clicking the continue button
    if (btn.contains(e.target)) return;

    pauseTour();
  };

  // Use capture phase so we intercept before the page handles the click
  document.addEventListener("click", interceptClick, true);

  // When a step shows, ensure we're not in paused state
  tour.on("show", () => {
    paused = false;
    document.body.classList.remove(PAUSE_CLASS);
    btn.style.display = "none";
  });

  // Clean up on tour end
  const cleanup = () => {
    document.removeEventListener("click", interceptClick, true);
    document.body.classList.remove(PAUSE_CLASS);
    btn.remove();
  };
  tour.on("complete", cleanup);
  tour.on("cancel", cleanup);
}

// ── Button builder ───────────────────────────────────────────────────────────

function buildButtons(keys, tour) {
  return keys.map((key) => {
    if (key === "next") {
      return {
        text: "Next",
        action: () => tour.next(),
        classes: "shepherd-button",
      };
    }
    if (key === "back") {
      return {
        text: "Back",
        action: () => tour.back(),
        classes: "shepherd-button shepherd-button-secondary",
      };
    }
    if (key === "done") {
      return {
        text: "Got it!",
        action: () => tour.complete(),
        classes: "shepherd-button",
      };
    }
    if (key === "finish-home") {
      return {
        text: "Back to home \u2192",
        classes: "shepherd-button",
        action: () => {
          tour._finishingHome = true;
          tour.complete();
          window.location.href = "/";
        },
      };
    }
    if (key === "navigate-resident") {
      return {
        text: "Let\u2019s go \u2192",
        classes: "shepherd-button",
        action: () => {
          const nameCell = document.querySelector(
            "td[data-tour-resident-name][data-cohort-graduation-year='2026']",
          );
          const link =
            nameCell && nameCell.querySelector("a[href^='/residents/']");
          if (link) {
            saveTourState({ resume: "resident" });
            tour.cancel();
            window.location.href = link.getAttribute("href");
          } else {
            tour.next();
          }
        },
      };
    }
    if (key === "navigate-calendar") {
      return {
        text: "Let\u2019s go \u2192",
        classes: "shepherd-button",
        action: () => navigateToPage("calendar", null, tour),
      };
    }
    if (key === "navigate-compare") {
      return {
        text: "Let\u2019s go \u2192",
        classes: "shepherd-button",
        action: () => navigateToPage("compare", null, tour),
      };
    }
    if (typeof key === "object" && key.key === "navigate") {
      return {
        text: key.label || "Continue \u2192",
        classes: "shepherd-button",
        action: () => navigateToPage(key.dest, key.startAt, tour),
      };
    }
    return key;
  });
}

// ── Tour factory ─────────────────────────────────────────────────────────────

// The demo is public and carries invented data, so the copy must not name the
// program. `brand` comes from the server via the brand-name meta tag.
function buildTour(page, startAtId, role, brand) {
  // Steps may scope themselves to roles, and title/text may be functions of
  // the role so the copy matches what the viewer actually sees.
  const steps = (STEP_SETS[page] || SCHEDULE_STEPS).filter(
    (s) => !s.roles || s.roles.includes(role),
  );

  let effectiveSteps = steps;
  if (startAtId) {
    const idx = steps.findIndex((s) => s.id === startAtId);
    if (idx > 0) {
      effectiveSteps = steps.slice(idx);
    }
  }

  const tour = new Shepherd.Tour({
    useModalOverlay: true,
    defaultStepOptions: {
      cancelIcon: { enabled: true },
      scrollTo: { behavior: "smooth", block: "center" },
      modalOverlayOpeningPadding: MODAL_PADDING,
      modalOverlayOpeningRadius: MODAL_RADIUS,
    },
  });

  for (const step of effectiveSteps) {
    tour.addStep({
      id: step.id,
      title:
        typeof step.title === "function" ? step.title(role, brand) : step.title,
      text: typeof step.text === "function" ? step.text(role, brand) : step.text,
      attachTo: step.attachTo,
      buttons: buildButtons(step.buttons || ["next"], tour),
    });
  }

  // Wire up pause/resume behavior
  setupPauseResume(tour);

  return tour;
}

export { buildTour, consumeTourState, saveTourState };
