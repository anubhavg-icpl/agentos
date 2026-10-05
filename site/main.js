// copy buttons and install tabs; the page works without this file
document.querySelectorAll(".cmd").forEach((box) => {
  const btn = box.querySelector(".copy");
  btn.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(box.dataset.copy);
      btn.textContent = "copied";
      btn.classList.add("done");
    } catch {
      btn.textContent = "select it";
    }
    setTimeout(() => {
      btn.textContent = "copy";
      btn.classList.remove("done");
    }, 1600);
  });
});

const tabs = document.querySelectorAll(".tabs button");
tabs.forEach((tab) => {
  tab.addEventListener("click", () => {
    tabs.forEach((t) => t.setAttribute("aria-selected", String(t === tab)));
    document.querySelectorAll("[data-panel]").forEach((p) => {
      p.hidden = p.dataset.panel !== tab.dataset.tab;
    });
  });
});
