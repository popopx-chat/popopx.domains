(function () {
  "use strict";
  var KEY = "popopx-theme";
  var root = document.documentElement;
  var stored = null;
  try {
    stored = window.localStorage.getItem(KEY);
  } catch (err) {
    stored = null;
  }
  var theme = stored;
  if (theme !== "light" && theme !== "dark") {
    theme =
      window.matchMedia &&
      window.matchMedia("(prefers-color-scheme: dark)").matches
        ? "dark"
        : "light";
  }
  root.setAttribute("data-theme", theme);
})();