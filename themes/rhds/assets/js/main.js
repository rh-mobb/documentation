/**
 * Headerless rh-alert: upstream sets shadow <header hidden>, which breaks icon/body alignment.
 * Fix (per RH Cloud Experts): drop hidden on that header and tighten .hasBody header spacing (4px → 2px).
 * Lit may re-apply hidden on render — MutationObserver re-runs the patch.
 */
const rhAlertStyleInjected = new WeakSet();
const rhAlertShadowObserved = new WeakSet();
const rhAlertHostWired = new WeakSet();

function patchHeaderlessRhAlert(alert) {
  if (!(alert instanceof HTMLElement) || alert.nodeName !== "RH-ALERT") {
    return;
  }
  if (alert.querySelector("[slot=\"header\"]")) {
    return;
  }

  const root = alert.shadowRoot;
  if (!root) {
    return;
  }

  const header = root.querySelector("#middle-column > header");
  if (header?.hasAttribute("hidden")) {
    header.removeAttribute("hidden");
  }

  if (!rhAlertStyleInjected.has(root)) {
    rhAlertStyleInjected.add(root);
    try {
      const sheet = new CSSStyleSheet();
      sheet.replaceSync(
        "#container.hasBody header { margin-block-end: 2px !important; }",
      );
      root.adoptedStyleSheets = [...root.adoptedStyleSheets, sheet];
    } catch {
      /* adoptedStyleSheets unsupported */
    }
  }
}

function wireHeaderlessRhAlert(alert) {
  if (!(alert instanceof HTMLElement) || alert.nodeName !== "RH-ALERT") {
    return;
  }
  if (alert.querySelector("[slot=\"header\"]")) {
    return;
  }
  if (rhAlertHostWired.has(alert)) {
    return;
  }
  rhAlertHostWired.add(alert);

  let attempts = 0;
  const run = () => {
    const root = alert.shadowRoot;
    if (!root) {
      if (attempts++ < 90) {
        requestAnimationFrame(run);
      }
      return;
    }

    patchHeaderlessRhAlert(alert);

    if (!rhAlertShadowObserved.has(root)) {
      rhAlertShadowObserved.add(root);
      const mo = new MutationObserver(() => {
        patchHeaderlessRhAlert(alert);
      });
      mo.observe(root, {
        subtree: true,
        childList: true,
        attributes: true,
        attributeFilter: ["hidden"],
      });
    }
  };

  alert.addEventListener("slotchange", () => {
    patchHeaderlessRhAlert(alert);
  });

  requestAnimationFrame(run);
}

function initHeaderlessRhAlertPatches() {
  document.querySelectorAll("rh-alert").forEach(wireHeaderlessRhAlert);
}

function boot() {
  requestAnimationFrame(() => {
    requestAnimationFrame(initHeaderlessRhAlertPatches);
  });
}

if (typeof customElements !== "undefined") {
  if (customElements.get("rh-alert")) {
    boot();
  } else {
    customElements.whenDefined("rh-alert").then(boot);
  }
}
