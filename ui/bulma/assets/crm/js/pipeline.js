/* SPDX-License-Identifier: AGPL-3.0-or-later
   Pipeline de la relation client (ADR-009 D3) : ce fichier n'ajoute que le
   confort. Sans lui, chaque carte se déplace par ses boutons « ← » et « → »
   (formulaires ordinaires, envoyés par HTMX s'il est chargé) ou par « Autre
   étape… ».

   * Souris : glisser-déposer d'une carte sur une colonne. Vers « Perdue »,
     l'écran « Changer d'étape » s'ouvre pour recueillir le motif.
   * Clavier, sur la carte qui a le focus (raccourcis actifs seulement
     là, WCAG 2.1.4) : Maj+← et Maj+→ déplacent la carte d'une étape ; ↑ et
     ↓ passent à la carte voisine de la colonne.
   * Après le remplacement du tableau, le focus revient sur la carte
     déplacée ; la région d'état annonce le déplacement. */
(function () {
  "use strict";
  var focusAfterSwap = null;

  function cardOf(element) {
    return element instanceof Element ? element.closest("[data-crm-card]") : null;
  }

  function send(card, stageId) {
    var form = card.querySelector("[data-crm-move]");
    if (!form) return;
    focusAfterSwap = card.id;
    if (window.htmx) {
      window.htmx.ajax("POST", form.getAttribute("action"), {
        source: form, values: { stage_id: stageId }, target: "#crm-board", select: "#crm-board", swap: "outerHTML"
      });
    } else {
      var input = document.createElement("input");
      input.type = "hidden";
      input.name = "stage_id";
      input.value = stageId;
      form.appendChild(input);
      form.submit();
    }
  }

  document.addEventListener("dragstart", function (event) {
    var card = cardOf(event.target);
    if (!card || !event.dataTransfer) return;
    event.dataTransfer.effectAllowed = "move";
    event.dataTransfer.setData("text/plain", card.getAttribute("data-crm-card"));
    card.classList.add("is-dragging");
  });

  document.addEventListener("dragend", function (event) {
    var card = cardOf(event.target);
    if (card) card.classList.remove("is-dragging");
    document.querySelectorAll(".crm-column.is-over").forEach(function (column) { column.classList.remove("is-over"); });
  });

  document.addEventListener("dragover", function (event) {
    var column = event.target instanceof Element ? event.target.closest("[data-crm-stage]") : null;
    if (!column) return;
    event.preventDefault();
    column.classList.add("is-over");
  });

  document.addEventListener("dragleave", function (event) {
    var column = event.target instanceof Element ? event.target.closest("[data-crm-stage]") : null;
    if (column && !column.contains(event.relatedTarget)) column.classList.remove("is-over");
  });

  document.addEventListener("drop", function (event) {
    var column = event.target instanceof Element ? event.target.closest("[data-crm-stage]") : null;
    if (!column || !event.dataTransfer) return;
    event.preventDefault();
    column.classList.remove("is-over");
    var card = document.getElementById("crm-card-" + event.dataTransfer.getData("text/plain"));
    if (!card || card.closest("[data-crm-stage]") === column) return;
    var stageId = column.getAttribute("data-crm-stage");
    if (column.getAttribute("data-crm-kind") === "lost") {
      var other = card.querySelector("[data-crm-other]");
      if (other) window.location.href = other.getAttribute("href") + "?stage=" + encodeURIComponent(stageId);
      return;
    }
    send(card, stageId);
  });

  document.addEventListener("keydown", function (event) {
    var card = event.target instanceof Element && event.target.matches("[data-crm-card]") ? event.target : null;
    if (!card || event.altKey || event.ctrlKey || event.metaKey) return;
    if (event.shiftKey && (event.key === "ArrowRight" || event.key === "ArrowLeft")) {
      var button = card.querySelector(event.key === "ArrowRight" ? "[data-crm-next]" : "[data-crm-prev]");
      if (button) {
        event.preventDefault();
        send(card, button.value);
      }
      return;
    }
    if (!event.shiftKey && (event.key === "ArrowDown" || event.key === "ArrowUp")) {
      var item = card.closest("li");
      var sibling = item && (event.key === "ArrowDown" ? item.nextElementSibling : item.previousElementSibling);
      var target = sibling && sibling.querySelector("[data-crm-card]");
      if (target) {
        event.preventDefault();
        target.focus();
      }
    }
  });

  // Bouton « ← » ou « → » envoyé par HTMX : le focus reviendra sur la carte.
  document.addEventListener("htmx:beforeRequest", function (event) {
    var card = cardOf(event.target);
    if (card) focusAfterSwap = card.id;
  });

  document.addEventListener("htmx:afterSettle", function () {
    if (!focusAfterSwap) return;
    var card = document.getElementById(focusAfterSwap);
    focusAfterSwap = null;
    if (card) card.focus();
  });
})();
