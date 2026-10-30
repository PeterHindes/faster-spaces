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

  const downloadCounter = document.querySelector("[data-download-count]");
  if (downloadCounter) {
    const cacheKey = "fasterspaces-downloads";
    const cacheTtl = 15 * 60 * 1000;
    const releasesApi =
      "https://api.github.com/repos/PeterHindes/faster-spaces/releases?per_page=100";

    const renderDownloads = (total) => {
      if (Number.isFinite(total)) {
        downloadCounter.textContent = total.toLocaleString("en-US");
      }
    };

    const readCache = () => {
      try {
        const cached = JSON.parse(localStorage.getItem(cacheKey) || "null");
        if (
          cached &&
          Number.isFinite(cached.total) &&
          typeof cached.at === "number"
        ) {
          return cached;
        }
      } catch {
        // Storage can be unavailable; fall through to a network read.
      }
      return null;
    };

    const cache = readCache();
    if (cache) {
      renderDownloads(cache.total);
    }

    if (!cache || Date.now() - cache.at > cacheTtl) {
      fetch(releasesApi, {
        headers: { Accept: "application/vnd.github+json" },
      })
        .then((response) => (response.ok ? response.json() : null))
        .then((releases) => {
          if (!Array.isArray(releases)) return;

          const total = releases.reduce((sum, release) => {
            if (!release || release.draft) return sum;
            const assets = Array.isArray(release.assets) ? release.assets : [];
            return (
              sum +
              assets
                .filter((asset) => asset && asset.name === "Faster-Spaces.zip")
                .reduce(
                  (count, asset) => count + (Number(asset.download_count) || 0),
                  0
                )
            );
          }, 0);

          renderDownloads(total);
          try {
            localStorage.setItem(
              cacheKey,
              JSON.stringify({ total, at: Date.now() })
            );
          } catch {
            // Storage can be unavailable; the counter still rendered.
          }
        })
        .catch(() => {
          // Keep the cached number, or the placeholder, when offline.
        });
    }
  }
})();
