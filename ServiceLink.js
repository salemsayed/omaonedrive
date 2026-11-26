.pragma library
// How a bar widget reaches its Service under any bar. A replacement bar's
// shell facade reaches no plugin services, so serviceFor() is null there. Qt
// loads one copy of a .pragma library per engine and URL, and Service.qml and
// BarWidget.qml import this file by the same path, so they share it.

var registered = null
var listeners = []

function notify() {
  listeners.forEach(function(listener) { listener() })
}

function register(service) {
  registered = service
  notify()
}

// A Service torn down after its replacement registered leaves the replacement.
function unregister(service) {
  if (registered !== service) return
  registered = null
  notify()
}

function current() {
  return registered
}

function subscribe(listener) {
  listeners.push(listener)
}

function unsubscribe(listener) {
  var index = listeners.indexOf(listener)
  if (index !== -1) listeners.splice(index, 1)
}
