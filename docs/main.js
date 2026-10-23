(() => {
  const buttons = document.querySelectorAll(".copy");

  const copyText = async (text) => {
    if (navigator.clipboard && window.isSecureContext) {
      await navigator.clipboard.writeText(text);
      return true;
    }
    const area = document.createElement("textarea");
    area.value = text;
    area.setAttribute("readonly", "");
    area.style.position = "fixed";
    area.style.opacity = "0";
    document.body.appendChild(area);
    area.select();
    const ok = document.execCommand("copy");
    area.remove();
    return ok;
  };

  for (const button of buttons) {
    button.addEventListener("click", async () => {
      const text = button.dataset.copy || "";
      const original = button.textContent;
      try {
        await copyText(text);
        button.textContent = "Copied";
        setTimeout(() => (button.textContent = original), 1400);
      } catch {
        button.textContent = "Select & copy";
      }
    });
  }

  const header = document.querySelector(".site-header");
  const onScroll = () => {
    if (!header) return;
    header.style.background = window.scrollY > 12
      ? "rgba(8, 10, 18, 0.9)"
      : "rgba(8, 10, 18, 0.72)";
  };
  window.addEventListener("scroll", onScroll, { passive: true });
  onScroll();
})();
