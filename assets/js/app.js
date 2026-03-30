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
import {hooks as colocatedHooks} from "phoenix-colocated/awardflights"
import topbar from "../vendor/topbar"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

const Hooks = {
  PersistForm: {
    mounted() {
      // Use data-storage-key attribute if provided, otherwise default to "scanner_form"
      this.storageKey = this.el.dataset.storageKey || "scanner_form"

      // Load saved values on mount
      const saved = localStorage.getItem(this.storageKey)
      if (saved) {
        try {
          const values = JSON.parse(saved)
          this.pushEvent("restore_form", values)
        } catch (e) {
          console.error("Failed to parse saved form data", e)
        }
      }

      // Save values on form change
      this.el.addEventListener("input", (e) => {
        this.saveForm()
      })

      this.el.addEventListener("change", (e) => {
        this.saveForm()
      })
    },

    saveForm() {
      const formData = new FormData(this.el)
      const values = {}

      // Get regular text inputs (non-credential fields)
      for (const [key, value] of formData.entries()) {
        // Skip credential fields - we'll handle them separately
        if (!key.startsWith("award_cred_") && !key.startsWith("offers_cred_")) {
          values[key] = value
        }
      }

      // Collect award credentials from indexed form fields
      const awardCredentials = []
      let awardIndex = 0
      while (true) {
        const nameEl = this.el.querySelector(`[name="award_cred_name_${awardIndex}"]`)
        const valueEl = this.el.querySelector(`[name="award_cred_value_${awardIndex}"]`)
        if (!nameEl || !valueEl) break
        awardCredentials.push({
          name: nameEl.value,
          value: valueEl.value
        })
        awardIndex++
      }
      if (awardCredentials.length > 0) {
        values.award_credentials = awardCredentials
      }

      // Collect offers credentials from indexed form fields
      const offersCredentials = []
      let offersIndex = 0
      while (true) {
        const nameEl = this.el.querySelector(`[name="offers_cred_name_${offersIndex}"]`)
        const cookiesEl = this.el.querySelector(`[name="offers_cred_cookies_${offersIndex}"]`)
        if (!nameEl || !cookiesEl) break
        offersCredentials.push({
          name: nameEl.value,
          cookies: cookiesEl.value,
          auth_token: "" // auth_token is extracted from cookies server-side
        })
        offersIndex++
      }
      if (offersCredentials.length > 0) {
        values.offers_credentials = offersCredentials
      }

      // Get checkbox states explicitly (unchecked checkboxes aren't in FormData)
      this.el.querySelectorAll('input[type="checkbox"]').forEach(cb => {
        values[cb.name] = cb.checked ? "true" : "false"
      })

      localStorage.setItem(this.storageKey, JSON.stringify(values))
    }
  },

  LocalTime: {
    mounted() {
      this.formatTime()
    },
    updated() {
      this.formatTime()
    },
    formatTime() {
      const utc = this.el.dataset.utc
      if (utc) {
        const date = new Date(utc)
        const options = {
          year: 'numeric',
          month: '2-digit',
          day: '2-digit',
          hour: '2-digit',
          minute: '2-digit',
          second: '2-digit',
          hour12: false
        }
        this.el.textContent = date.toLocaleString(undefined, options)
      }
    }
  },

  RateLimitCountdown: {
    mounted() {
      this.updateDisplay()
      this.interval = setInterval(() => this.updateDisplay(), 1000)
    },
    updated() {
      this.updateDisplay()
    },
    destroyed() {
      if (this.interval) {
        clearInterval(this.interval)
      }
    },
    updateDisplay() {
      const utc = this.el.dataset.utc
      if (!utc) {
        this.el.textContent = ""
        return
      }

      const endTime = new Date(utc)
      const now = new Date()
      const diffMs = endTime - now

      if (diffMs <= 0) {
        this.el.textContent = "Expired"
        if (this.interval) {
          clearInterval(this.interval)
        }
        return
      }

      // Format the end time in local timezone
      const timeOptions = {
        hour: '2-digit',
        minute: '2-digit',
        hour12: true
      }
      const localTime = endTime.toLocaleTimeString(undefined, timeOptions)

      // Calculate countdown
      const totalSeconds = Math.floor(diffMs / 1000)
      const hours = Math.floor(totalSeconds / 3600)
      const minutes = Math.floor((totalSeconds % 3600) / 60)
      const seconds = totalSeconds % 60

      let countdown
      if (hours > 0) {
        countdown = `${hours}h ${minutes}m ${seconds}s`
      } else if (minutes > 0) {
        countdown = `${minutes}m ${seconds}s`
      } else {
        countdown = `${seconds}s`
      }

      this.el.textContent = `Rate limited until ${localTime} (${countdown})`
    }
  }
}

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ...Hooks},
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

