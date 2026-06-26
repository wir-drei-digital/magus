/**
 * ServiceCapture LiveView Hook
 *
 * Provides rectangle selection on the sandbox service iframe for
 * capturing screenshots to send to the chat.
 *
 * Activated by clicking the camera icon in the service pane header.
 * Uses html-to-image (SVG foreignObject) to capture the iframe content
 * (same-origin via proxy), preserving native text rendering, then crops
 * the selected region.
 *
 * Usage: <div phx-hook="ServiceCapture">
 */
import { toCanvas } from "html-to-image";

const MAX_IMAGE_BYTES = 2_000_000; // ~2MB limit for base64 payload

const ServiceCapture = {
  mounted() {
    this.capturing = false;
    this.selection = null;
    this.selectionRect = null;
    this.askButton = null;
    this.overlay = null;

    this.handleEvent("service_capture:toggle", () => {
      if (this.capturing) {
        this.exitCaptureMode();
      } else {
        this.enterCaptureMode();
      }
    });

    this.handleEvent("service_capture:exit", () => {
      this.exitCaptureMode();
    });

    this._onKeyDown = (e) => {
      if (e.key === "Escape" && this.capturing) {
        this.exitCaptureMode();
        this.pushEvent("service_capture:mode_changed", { active: false });
      }
    };
    document.addEventListener("keydown", this._onKeyDown);
  },

  destroyed() {
    document.removeEventListener("keydown", this._onKeyDown);
    this.exitCaptureMode();
  },

  enterCaptureMode() {
    this.capturing = true;

    const contentArea = this.el.querySelector(".service-capture-area");
    if (!contentArea) return;

    // Create overlay on top of the iframe
    this.overlay = document.createElement("div");
    this.overlay.className = "service-capture-overlay";
    this.overlay.style.position = "absolute";
    this.overlay.style.inset = "0";
    this.overlay.style.cursor = "crosshair";
    this.overlay.style.zIndex = "5";
    this.overlay.style.background = "oklch(0 0 0 / 0.05)";

    this.setupSelectionHandlers(this.overlay);
    contentArea.style.position = "relative";
    contentArea.appendChild(this.overlay);
  },

  exitCaptureMode() {
    this.capturing = false;
    this.clearSelection();
    if (this.overlay) {
      this.overlay.remove();
      this.overlay = null;
    }
  },

  setupSelectionHandlers(overlay) {
    let isSelecting = false;
    let startX, startY;

    overlay.addEventListener("mousedown", (e) => {
      if (e.target.closest(".pdf-ask-button")) return;

      this.clearSelection();
      isSelecting = true;

      const rect = overlay.getBoundingClientRect();
      startX = e.clientX - rect.left;
      startY = e.clientY - rect.top;

      this.selectionRect = this.createSelectionRect(startX, startY);
      overlay.appendChild(this.selectionRect);
    });

    overlay.addEventListener("mousemove", (e) => {
      if (!isSelecting || !this.selectionRect) return;

      const rect = overlay.getBoundingClientRect();
      const currentX = e.clientX - rect.left;
      const currentY = e.clientY - rect.top;

      const x = Math.min(startX, currentX);
      const y = Math.min(startY, currentY);
      const w = Math.abs(currentX - startX);
      const h = Math.abs(currentY - startY);

      this.selectionRect.style.left = `${x}px`;
      this.selectionRect.style.top = `${y}px`;
      this.selectionRect.style.width = `${w}px`;
      this.selectionRect.style.height = `${h}px`;
    });

    overlay.addEventListener("mouseup", (e) => {
      if (!isSelecting || !this.selectionRect) return;
      isSelecting = false;

      const rect = overlay.getBoundingClientRect();
      const currentX = e.clientX - rect.left;
      const currentY = e.clientY - rect.top;

      const x = Math.min(startX, currentX);
      const y = Math.min(startY, currentY);
      const w = Math.abs(currentX - startX);
      const h = Math.abs(currentY - startY);

      // Minimum selection size (10px)
      if (w < 10 || h < 10) {
        this.clearSelection();
        return;
      }

      this.selection = { x, y, w, h };
      this.showAskButton(overlay, x, y, w, h);
    });

    // Touch events for mobile
    let touchStartX, touchStartY;

    overlay.addEventListener(
      "touchstart",
      (e) => {
        if (e.touches.length !== 1) return;
        if (e.target.closest(".pdf-ask-button")) return;
        this.clearSelection();
        isSelecting = true;

        const touch = e.touches[0];
        const rect = overlay.getBoundingClientRect();
        startX = touch.clientX - rect.left;
        startY = touch.clientY - rect.top;
        touchStartX = startX;
        touchStartY = startY;

        this.selectionRect = this.createSelectionRect(startX, startY);
        overlay.appendChild(this.selectionRect);
      },
      { passive: true },
    );

    overlay.addEventListener(
      "touchmove",
      (e) => {
        if (!isSelecting || !this.selectionRect || e.touches.length !== 1)
          return;
        e.preventDefault();

        const touch = e.touches[0];
        const rect = overlay.getBoundingClientRect();
        const currentX = touch.clientX - rect.left;
        const currentY = touch.clientY - rect.top;

        const x = Math.min(touchStartX, currentX);
        const y = Math.min(touchStartY, currentY);
        const w = Math.abs(currentX - touchStartX);
        const h = Math.abs(currentY - touchStartY);

        this.selectionRect.style.left = `${x}px`;
        this.selectionRect.style.top = `${y}px`;
        this.selectionRect.style.width = `${w}px`;
        this.selectionRect.style.height = `${h}px`;
      },
      { passive: false },
    );

    overlay.addEventListener("touchend", () => {
      if (!isSelecting || !this.selectionRect) return;
      isSelecting = false;

      const rectStyle = this.selectionRect.style;
      const x = parseFloat(rectStyle.left);
      const y = parseFloat(rectStyle.top);
      const w = parseFloat(rectStyle.width);
      const h = parseFloat(rectStyle.height);

      if (w < 10 || h < 10) {
        this.clearSelection();
        return;
      }

      this.selection = { x, y, w, h };
      this.showAskButton(overlay, x, y, w, h);
    });
  },

  createSelectionRect(x, y) {
    const rect = document.createElement("div");
    rect.className = "pdf-selection-rect";
    rect.style.position = "absolute";
    rect.style.left = `${x}px`;
    rect.style.top = `${y}px`;
    rect.style.width = "0px";
    rect.style.height = "0px";

    for (const pos of ["tl", "tr", "bl", "br"]) {
      const corner = document.createElement("div");
      corner.className = `pdf-selection-corner pdf-selection-corner--${pos}`;
      rect.appendChild(corner);
    }

    return rect;
  },

  showAskButton(overlay, x, y, w, h) {
    this.removeAskButton();

    this.askButton = document.createElement("button");
    this.askButton.className = "pdf-ask-button";
    this.askButton.innerHTML = `<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M7.9 20A9 9 0 1 0 4 16.1L2 22Z"/></svg> Ask`;

    this.askButton.style.position = "absolute";
    this.askButton.style.zIndex = "10";

    // Position inside the selection, bottom-right corner with padding
    const overlayRect = overlay.getBoundingClientRect();
    const btnWidth = 72; // approximate button width
    const btnHeight = 32;
    const pad = 8;

    // Try right of selection first; if it overflows, place inside bottom-right
    let left = x + w + 4;
    let top = y + h - btnHeight;

    if (left + btnWidth > overlayRect.width) {
      left = x + w - btnWidth - pad;
    }
    if (top + btnHeight > overlayRect.height) {
      top = overlayRect.height - btnHeight - pad;
    }
    if (top < y) {
      top = y + pad;
    }

    this.askButton.style.left = `${left}px`;
    this.askButton.style.top = `${top}px`;

    this.askButton.addEventListener("click", (e) => {
      e.stopPropagation();
      this.captureAndSend();
    });

    overlay.appendChild(this.askButton);
  },

  async captureAndSend() {
    if (!this.selection || !this.overlay) return;

    const { x, y, w, h } = this.selection;
    const iframe = this.el.querySelector("#service-preview-iframe");
    if (!iframe) return;

    // Show loading state on the Ask button
    if (this.askButton) {
      this.askButton.innerHTML = `<span class="loading loading-spinner loading-xs"></span>`;
      this.askButton.style.pointerEvents = "none";
    }

    try {
      let base64;

      // Use html-to-image (SVG foreignObject) for accurate text rendering
      try {
        const iframeDoc = iframe.contentDocument || iframe.contentWindow.document;
        const overlayRect = this.overlay.getBoundingClientRect();
        const dpr = Math.min(window.devicePixelRatio || 1, 2);

        // Render the visible iframe content to canvas at HiDPI resolution
        const canvas = await toCanvas(iframeDoc.body, {
          pixelRatio: dpr,
          width: Math.round(overlayRect.width),
          height: Math.round(overlayRect.height),
        });

        // Crop the selected region
        const scale = canvas.width / overlayRect.width;
        const sx = Math.round(x * scale);
        const sy = Math.round(y * scale);
        const sw = Math.round(w * scale);
        const sh = Math.round(h * scale);

        const cropCanvas = document.createElement("canvas");
        cropCanvas.width = sw;
        cropCanvas.height = sh;
        cropCanvas.getContext("2d").drawImage(canvas, sx, sy, sw, sh, 0, 0, sw, sh);

        base64 = cropCanvas.toDataURL("image/png");
      } catch {
        // Fallback: capture a placeholder when iframe content is inaccessible
        const dpr = Math.min(window.devicePixelRatio || 1, 2);
        const fallbackCanvas = document.createElement("canvas");
        fallbackCanvas.width = Math.round(w * dpr);
        fallbackCanvas.height = Math.round(h * dpr);
        const ctx = fallbackCanvas.getContext("2d");
        ctx.fillStyle = "#f3f4f6";
        ctx.fillRect(0, 0, fallbackCanvas.width, fallbackCanvas.height);
        ctx.fillStyle = "#6b7280";
        ctx.font = `${14 * dpr}px sans-serif`;
        ctx.textAlign = "center";
        ctx.fillText(
          "Screenshot captured",
          fallbackCanvas.width / 2,
          fallbackCanvas.height / 2,
        );
        base64 = fallbackCanvas.toDataURL("image/png");
      }

      // Enforce size limit
      if (base64.length > MAX_IMAGE_BYTES) {
        const img = new Image();
        await new Promise((resolve) => {
          img.onload = resolve;
          img.src = base64;
        });
        const ratio = Math.sqrt(MAX_IMAGE_BYTES / base64.length);
        const smallCanvas = document.createElement("canvas");
        smallCanvas.width = Math.round(img.width * ratio);
        smallCanvas.height = Math.round(img.height * ratio);
        smallCanvas.getContext("2d").drawImage(img, 0, 0, smallCanvas.width, smallCanvas.height);
        base64 = smallCanvas.toDataURL("image/jpeg", 0.75);
      }

      this.pushEvent("service:ask_about_selection", { image: base64 });
    } catch (err) {
      console.error("Service capture failed:", err);
    }

    this.exitCaptureMode();
    this.pushEvent("service_capture:mode_changed", { active: false });
  },

  clearSelection() {
    if (this.selectionRect) {
      this.selectionRect.remove();
      this.selectionRect = null;
    }
    this.removeAskButton();
    this.selection = null;
  },

  removeAskButton() {
    if (this.askButton) {
      this.askButton.remove();
      this.askButton = null;
    }
  },
};

export default ServiceCapture;
