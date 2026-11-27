(function () {
  "use strict";
  var KEY = "popopx-theme";
  var root = document.documentElement;
  var btn = document.getElementById("themeToggle");
  if (!btn) return;

  function current() {
    return root.getAttribute("data-theme") === "dark" ? "dark" : "light";
  }

  function paint() {
    var dark = current() === "dark";
    btn.setAttribute("aria-pressed", dark ? "true" : "false");
    btn.setAttribute("aria-label", dark ? "切换到浅色模式" : "切换到深色模式");
  }

  btn.addEventListener("click", function () {
    var next = current() === "dark" ? "light" : "dark";
    root.setAttribute("data-theme", next);
    try {
      window.localStorage.setItem(KEY, next);
    } catch (err) {
      /* storage unavailable: the choice still applies to this page view */
    }
    paint();
  });

  paint();

  if (window.matchMedia) {
    var mq = window.matchMedia("(prefers-color-scheme: dark)");
    var followSystem = function (event) {
      var stored = null;
      try {
        stored = window.localStorage.getItem(KEY);
      } catch (err) {
        stored = null;
      }
      if (stored === "light" || stored === "dark") return;
      root.setAttribute("data-theme", event.matches ? "dark" : "light");
      paint();
    };
    if (typeof mq.addEventListener === "function") {
      mq.addEventListener("change", followSystem);
    } else if (typeof mq.addListener === "function") {
      mq.addListener(followSystem);
    }
  }
})();