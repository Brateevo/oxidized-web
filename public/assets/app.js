(function () {
  "use strict";

  /* flash auto-hide */
  var flash = document.getElementById("flash");
  if (flash) {
    setTimeout(function () { flash.style.opacity = "0"; flash.style.transition = "opacity 1s"; }, 3000);
  }

  /* dev table search */
  var searchEl = document.getElementById("dev-search");
  if (searchEl) {
    searchEl.addEventListener("input", function () {
      var q = searchEl.value.toLowerCase();
      document.querySelectorAll("#dev-table tbody tr.dev-row").forEach(function (row) {
        var hit = (row.textContent || "").toLowerCase().indexOf(q) !== -1;
        row.style.display = hit ? "" : "none";
      });
    });
  }

  /* copy buttons */
  document.querySelectorAll("#btn-copy").forEach(function (btn) {
    btn.addEventListener("click", function () {
      var pre = document.getElementById("config-pre") || document.querySelector(".code");
      if (!pre) return;
      var text = pre.innerText || pre.textContent || "";
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(function () {
          var old = btn.textContent;
          btn.textContent = "Скопировано ✓";
          setTimeout(function () { btn.textContent = old; }, 1500);
        });
      }
    });
  });

  /* show/hide password */
  var eye = document.getElementById("btn-eye");
  if (eye) {
    eye.addEventListener("click", function () {
      var pw = document.getElementById("pw");
      pw.type = pw.type === "password" ? "text" : "password";
    });
  }

  /* password strength meter */
  function strength(s) {
    var score = 0;
    if (s.length >= 8) score++;
    if (s.length >= 12) score++;
    if (/[A-Z]/.test(s)) score++;
    if (/[a-z]/.test(s)) score++;
    if (/[0-9]/.test(s)) score++;
    if (/\W/.test(s) && s.length > 4) score++;
    return Math.min(score, 10);
  }
  var newpw = document.getElementById("newpw");
  if (newpw) {
    newpw.addEventListener("input", function () {
      var m = document.getElementById("newpw" + "meter") || null;
      if (m) m.value = strength(newpw.value);
    });
  }
  document.querySelectorAll("[id^=pw]").forEach(function (el) {
    if (el.id === "newpw" || el.id === "pw") return;
    var meter = document.getElementById("pwmeter" + el.id.replace("pw", ""));
    if (!meter) return;
    el.addEventListener("input", function () { meter.value = strength(el.value); });
  });

  /* modals */
  var openClose = function (popup, show) {
    var visible = null;
    document.querySelectorAll(".modal[data-popup]").forEach(function (m) {
      if (m.getAttribute("data-popup") === popup) {
        m.classList.toggle("hidden", !show);
        visible = m;
      } else {
        m.classList.add("hidden");
      }
    });
    return visible;
  };

  document.querySelectorAll("[data-open]").forEach(function (btn) {
    btn.addEventListener("click", function () {
      var modal = openClose(btn.getAttribute("data-open"), true);
      if (modal) {
        var f = modal.querySelector(".cb-filter");
        if (f) { f.value = ""; filterGrid(f); }
      }
    });
  });

  function filterGrid(inputEl) {
    var grid = inputEl.closest(".modal-card").querySelector("[data-cbgrid]");
    if (!grid) return;
    var q = inputEl.value.toLowerCase();
    grid.querySelectorAll("label.cb").forEach(function (lb) {
      var sel = lb.querySelector("[data-selall]");
      if (sel) { lb.style.display = ""; return; }
      var hit = (lb.textContent || "").toLowerCase().indexOf(q) !== -1;
      lb.style.display = hit ? "" : "none";
    });
  }

  document.querySelectorAll(".cb-filter").forEach(function (f) {
    f.addEventListener("input", function () { filterGrid(f); });
  });

  document.querySelectorAll("[data-close]").forEach(function (btn) {
    btn.addEventListener("click", function () {
      var m = btn.closest(".modal");
      if (m) m.classList.add("hidden");
    });
  });

  /* select all */
  document.querySelectorAll("[data-selall]").forEach(function (sel) {
    sel.addEventListener("change", function () {
      var grid = sel.closest(".modal-card");
      var all = grid.querySelectorAll("label.cb input[type=checkbox]");
      all.forEach(function (cb) { cb.checked = sel.checked; });
    });
  });

  /* close on ESC and click outside */
  document.addEventListener("click", function (e) {
    if (e.target.classList && e.target.classList.contains("modal")) {
      e.target.classList.add("hidden");
    }
  });
  document.addEventListener("keydown", function (e) {
    if (e.key === "Escape") {
      document.querySelectorAll(".modal:not(.hidden)").forEach(function (m) { m.classList.add("hidden"); });
    }
  });
})();