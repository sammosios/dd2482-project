// The little client-side glue htmx leaves to us: the sidebar toggle, the
// dialog the create/edit forms load into, styled confirmations and toasts.
// Everything else is HTML rendered by the server.
(function () {
  "use strict";

  document.addEventListener("click", function (e) {
    if (e.target.closest("[data-sidebar-toggle]")) {
      document.documentElement.classList.toggle("sidebar-toggled");
    }
  });

  var modal = document.getElementById("modal");
  var confirmDialog = document.getElementById("confirm");
  var toaster = document.getElementById("toaster");
  var toastIcons = document.getElementById("toast-icons");
  if (!modal) return; // sign-in pages have none of this

  // Buttons load a form into #modal (hx-target="#modal"); show it once it's there.
  document.body.addEventListener("htmx:afterSwap", function (e) {
    if (e.detail.target === modal && !modal.open) modal.showModal();
  });
  // Sent by the server in HX-Trigger after a successful save.
  document.body.addEventListener("closeModal", function () {
    modal.close();
  });
  // Close on Cancel / the X, and on clicks on the backdrop around the dialog.
  modal.addEventListener("click", function (e) {
    if (e.target === modal || e.target.closest("[data-close]")) modal.close();
  });

  // hx-confirm, but with a dialog that looks like the rest of the app
  // instead of the browser's confirm().
  document.body.addEventListener("htmx:confirm", function (e) {
    if (!e.detail.question) return; // no hx-confirm on this element
    e.preventDefault();
    var elt = e.detail.elt;
    confirmDialog.querySelector("[data-confirm-title]").textContent = elt.dataset.confirmTitle || "Are you sure?";
    confirmDialog.querySelector("[data-confirm-text]").textContent = e.detail.question;
    confirmDialog.querySelector("[data-confirm-action]").textContent = elt.dataset.confirmAction || "Continue";
    confirmDialog.returnValue = "";
    confirmDialog.addEventListener("close", function () {
      if (confirmDialog.returnValue === "confirm") e.detail.issueRequest(true);
    }, { once: true });
    confirmDialog.showModal();
  });

  function toast(message, kind) {
    var el = document.createElement("div");
    el.className = "toast toast-" + kind;
    el.setAttribute("role", kind === "error" ? "alert" : "status");
    var icon = toastIcons.content.querySelector('[data-kind="' + kind + '"] svg');
    if (icon) el.appendChild(icon.cloneNode(true));
    var text = document.createElement("span");
    text.textContent = message;
    el.appendChild(text);
    toaster.appendChild(el);
    setTimeout(function () {
      el.classList.add("is-leaving");
      setTimeout(function () { el.remove(); }, 200);
    }, 4000);
  }

  // Success messages come from the server: HX-Trigger: {"toast": "..."}.
  document.body.addEventListener("toast", function (e) {
    toast(e.detail.value, "success");
  });
  // Errors (403, 404, 500...) come back as plain text.
  document.body.addEventListener("htmx:responseError", function (e) {
    var xhr = e.detail.xhr;
    toast((xhr.responseText || "").trim() || "Request failed (" + xhr.status + ")", "error");
  });
  document.body.addEventListener("htmx:sendError", function () {
    toast("Couldn't reach the server.", "error");
  });
})();
