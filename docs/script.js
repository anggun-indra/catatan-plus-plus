// Catatan++ Website Scripts
document.addEventListener('DOMContentLoaded', () => {
  // 1. Interactive Screenshot Switcher
  const tabs = document.querySelectorAll('.tab-btn');
  const showcaseImg = document.getElementById('showcaseImg');
  const windowTitleText = document.getElementById('windowTitleText');

  if (tabs.length && showcaseImg) {
    tabs.forEach(tab => {
      tab.addEventListener('click', () => {
        tabs.forEach(t => t.classList.remove('active'));
        tab.classList.add('active');

        const target = tab.getAttribute('data-target');
        const title = tab.getAttribute('data-title');
        if (title && windowTitleText) {
          windowTitleText.textContent = title;
        }
        if (target) {
          showcaseImg.style.opacity = '0.3';
          setTimeout(() => {
            showcaseImg.src = `assets/${target}`;
            showcaseImg.style.opacity = '1';
          }, 150);
        }
      });
    });
  }

  // 2. Dynamic GitHub Release Fetcher
  const repoOwner = 'anggun-indra';
  const repoName = 'catatan-plus-plus';
  const apiURL = `https://api.github.com/repos/${repoOwner}/${repoName}/releases/latest`;

  const versionText = document.getElementById('versionText');
  const primaryDownloadBtn = document.getElementById('primaryDownloadBtn');
  const dmgSubLabel = document.getElementById('dmgSubLabel');
  const matrixDmgBtn = document.getElementById('matrixDmgBtn');
  const matrixZipBtn = document.getElementById('matrixZipBtn');

  // Fallback defaults
  const fallbackVersion = 'v1.0.4';
  const fallbackDmgURL = `https://github.com/${repoOwner}/${repoName}/releases/download/${fallbackVersion}/Catatan%2B%2B-${fallbackVersion}-macOS-arm64.dmg`;
  const fallbackZipURL = `https://github.com/${repoOwner}/${repoName}/releases/download/${fallbackVersion}/Catatan%2B%2B-${fallbackVersion}-macOS-arm64.zip`;

  fetch(apiURL)
    .then(res => {
      if (!res.ok) throw new Error('API fetch failed');
      return res.json();
    })
    .then(data => {
      const tag = data.tag_name || fallbackVersion;
      if (versionText) {
        versionText.textContent = `${tag} • Apple Silicon Native`;
      }

      let dmgURL = fallbackDmgURL;
      let zipURL = fallbackZipURL;
      let dmgSize = '3.6 MB';

      if (Array.isArray(data.assets)) {
        for (const asset of data.assets) {
          if (asset.name.endsWith('.dmg')) {
            dmgURL = asset.browser_download_url;
            if (asset.size) {
              dmgSize = `${(asset.size / (1024 * 1024)).toFixed(1)} MB`;
            }
          } else if (asset.name.endsWith('.zip')) {
            zipURL = asset.browser_download_url;
          }
        }
      }

      if (primaryDownloadBtn) {
        primaryDownloadBtn.href = dmgURL;
      }
      if (dmgSubLabel) {
        dmgSubLabel.textContent = `macOS 11+ • DMG (${dmgSize}) • ${tag}`;
      }
      if (matrixDmgBtn) {
        matrixDmgBtn.href = dmgURL;
      }
      if (matrixZipBtn) {
        matrixZipBtn.href = zipURL;
      }
    })
    .catch(err => {
      console.warn('Could not fetch latest release from GitHub API, using static fallbacks:', err);
      if (primaryDownloadBtn) primaryDownloadBtn.href = fallbackDmgURL;
      if (matrixDmgBtn) matrixDmgBtn.href = fallbackDmgURL;
      if (matrixZipBtn) matrixZipBtn.href = fallbackZipURL;
    });

  // 3. Command Copy Helpers (Homebrew & Gatekeeper)
  function setupCopyButton(btnId, textToCopy) {
    const btn = document.getElementById(btnId);
    if (!btn) return;
    btn.addEventListener('click', async () => {
      try {
        await navigator.clipboard.writeText(textToCopy);
        const originalHTML = btn.innerHTML;
        btn.classList.add('copied');
        btn.innerHTML = `<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="20 6 9 17 4 12"></polyline></svg><span>Copied!</span>`;
        setTimeout(() => {
          btn.classList.remove('copied');
          btn.innerHTML = originalHTML;
        }, 2000);
      } catch (e) {
        console.warn('Clipboard copy failed:', e);
      }
    });
  }

  setupCopyButton('copyBrewBtn', 'brew install --cask anggun-indra/tap/catatan-plus-plus');
  setupCopyButton('copyXattrBtn', 'xattr -cr /Applications/Catatan++.app');
});
