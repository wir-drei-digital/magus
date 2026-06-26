/**
 * PdfViewer LiveView Hook
 *
 * Renders a PDF using PDF.js and provides rectangle selection for
 * capturing regions as screenshots to send to the chat.
 *
 * Usage: <div phx-hook="PdfViewer" data-pdf-url="/path/to/file.pdf">
 */
import * as pdfjsLib from "pdfjs-dist";

pdfjsLib.GlobalWorkerOptions.workerSrc = "/assets/js/pdf.worker.min.mjs";

const DEFAULT_SCALE = 1.0; // 100% = 1 PDF point per CSS pixel
const MAX_IMAGE_BYTES = 2_000_000; // ~2MB limit for base64 payload

const PdfViewer = {
  mounted() {
    this.pdf = null;
    this.pages = [];
    this.selection = null;
    this.selectionRect = null;
    this.askButton = null;
    this.activePage = null;
    this.currentScale = DEFAULT_SCALE;

    const url = this.el.dataset.pdfUrl;
    if (url) {
      this.loadPdf(url);
    }

    this.handleEvent("pdf_viewer:load", ({ url }) => {
      this.destroyPdf();
      this.loadPdf(url);
    });

    this.handleEvent("pdf_viewer:zoom", ({ scale }) => {
      this.setZoom(scale);
    });
  },

  async loadPdf(url) {
    try {
      const loadingTask = pdfjsLib.getDocument(url);
      this.pdf = await loadingTask.promise;

      // Report page count to the server
      this.pushEventTo(this.el, "pdf:page_count", {
        count: this.pdf.numPages,
      });

      const container = this.el.querySelector(".pdf-viewer-pages");
      if (!container) return;
      container.innerHTML = "";

      for (let i = 1; i <= this.pdf.numPages; i++) {
        const page = await this.pdf.getPage(i);
        const pageWrapper = this.createPageElement(page, i, container);
        this.pages.push(pageWrapper);
      }
    } catch (err) {
      console.error("Failed to load PDF:", err);
    }
  },

  createPageElement(page, pageNumber, container) {
    const cssViewport = page.getViewport({ scale: this.currentScale });
    // Render at 2x for crisp text on HiDPI displays
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const renderViewport = page.getViewport({ scale: this.currentScale * dpr });

    // Page wrapper — sized to CSS viewport
    const wrapper = document.createElement("div");
    wrapper.className = "pdf-page-wrapper";
    wrapper.dataset.pageNumber = pageNumber;
    wrapper.style.position = "relative";
    // At default scale or below, fit to container width; above, allow overflow
    wrapper.style.width = `${cssViewport.width}px`;
    if (this.currentScale <= DEFAULT_SCALE) {
      wrapper.style.maxWidth = "100%";
    }

    // Canvas — backing at render resolution, displayed at CSS size
    const canvas = document.createElement("canvas");
    canvas.className = "pdf-page-canvas";
    canvas.width = renderViewport.width;
    canvas.height = renderViewport.height;
    canvas.style.width = "100%";
    canvas.style.height = "auto";
    canvas.style.display = "block";

    const ctx = canvas.getContext("2d");
    page.render({ canvasContext: ctx, viewport: renderViewport });

    // Selection overlay (transparent, captures mouse events)
    const overlay = document.createElement("div");
    overlay.className = "pdf-selection-overlay";
    overlay.style.position = "absolute";
    overlay.style.inset = "0";
    overlay.style.cursor = "crosshair";
    overlay.style.zIndex = "1";

    this.setupSelectionHandlers(overlay, canvas, pageNumber);

    wrapper.appendChild(canvas);
    wrapper.appendChild(overlay);
    container.appendChild(wrapper);

    return { wrapper, canvas, overlay, page, pageNumber };
  },

  setupSelectionHandlers(overlay, canvas, pageNumber) {
    let isSelecting = false;
    let startX, startY;

    overlay.addEventListener("mousedown", (e) => {
      // Don't start a new selection if clicking the Ask button
      if (e.target.closest(".pdf-ask-button")) return;

      this.clearSelection();
      isSelecting = true;

      const rect = overlay.getBoundingClientRect();
      startX = e.clientX - rect.left;
      startY = e.clientY - rect.top;

      this.selectionRect = this.createSelectionRect(startX, startY);
      overlay.appendChild(this.selectionRect);

      this.activePage = pageNumber;
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

      this.selection = { x, y, w, h, pageNumber, overlay, canvas };
      this.showAskButton(overlay, x, y, w, h);
    });

    // Also handle touch events for mobile
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

        this.activePage = pageNumber;
      },
      { passive: true },
    );

    overlay.addEventListener(
      "touchmove",
      (e) => {
        if (!isSelecting || !this.selectionRect || e.touches.length !== 1)
          return;
        e.preventDefault(); // Prevent scrolling while drawing selection

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

    overlay.addEventListener("touchend", (e) => {
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

      this.selection = { x, y, w, h, pageNumber, overlay, canvas };
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

    // Corner handles for contrast on any background
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

    // Position near the bottom-right of the selection
    this.askButton.style.position = "absolute";
    this.askButton.style.left = `${x + w + 4}px`;
    this.askButton.style.top = `${y + h - 32}px`;
    this.askButton.style.zIndex = "10";

    this.askButton.addEventListener("click", (e) => {
      e.stopPropagation();
      this.captureAndSend();
    });

    overlay.appendChild(this.askButton);
  },

  async captureAndSend() {
    if (!this.selection) return;

    const { x, y, w, h, pageNumber, overlay, canvas } = this.selection;

    // Map overlay coordinates to canvas pixel coordinates
    const overlayRect = overlay.getBoundingClientRect();
    const scaleX = canvas.width / overlayRect.width;
    const scaleY = canvas.height / overlayRect.height;

    const sx = Math.round(x * scaleX);
    const sy = Math.round(y * scaleY);
    const sw = Math.round(w * scaleX);
    const sh = Math.round(h * scaleY);

    // Crop from the canvas
    const ctx = canvas.getContext("2d");
    const imageData = ctx.getImageData(sx, sy, sw, sh);

    const tempCanvas = document.createElement("canvas");
    tempCanvas.width = sw;
    tempCanvas.height = sh;
    tempCanvas.getContext("2d").putImageData(imageData, 0, 0);

    let base64 = tempCanvas.toDataURL("image/jpeg", 0.85);

    // Enforce size limit — downscale if too large
    if (base64.length > MAX_IMAGE_BYTES) {
      const ratio = Math.sqrt(MAX_IMAGE_BYTES / base64.length);
      const smallCanvas = document.createElement("canvas");
      smallCanvas.width = Math.round(sw * ratio);
      smallCanvas.height = Math.round(sh * ratio);
      smallCanvas
        .getContext("2d")
        .drawImage(tempCanvas, 0, 0, smallCanvas.width, smallCanvas.height);
      base64 = smallCanvas.toDataURL("image/jpeg", 0.75);
    }

    // Extract text within the selection bounds using PDF.js textContent
    // Overlay coords are in CSS pixels; text items are in viewport space.
    // Scale overlay coords to viewport space using the overlay-to-viewport ratio.
    let extractedText = "";
    try {
      const pageData = this.pages.find((p) => p.pageNumber === pageNumber);
      if (pageData) {
        const textContent = await pageData.page.getTextContent();
        const viewport = pageData.page.getViewport({ scale: this.currentScale });

        // Overlay may be smaller than viewport due to maxWidth:100%
        const ovScale = viewport.width / overlayRect.width;
        const selX = x * ovScale;
        const selY = y * ovScale;
        const selW = w * ovScale;
        const selH = h * ovScale;

        extractedText = textContent.items
          .filter((item) => {
            const tx = item.transform[4];
            // PDF y-coordinates are bottom-up, viewport transforms to top-down
            const ty = viewport.height - item.transform[5];
            const tw = item.width;
            const th = item.height || 12;

            return (
              tx < selX + selW &&
              tx + tw > selX &&
              ty < selY + selH &&
              ty + th > selY
            );
          })
          .map((item) => item.str)
          .join(" ")
          .trim();
      }
    } catch (err) {
      console.warn("Could not extract text from selection:", err);
    }

    // pushEvent (not pushEventTo) — routes to the parent LiveView,
    // which manages the pdf_selection assign and message dispatch
    this.pushEvent("pdf:ask_about_selection", {
      image: base64,
      text: extractedText,
      page: pageNumber,
    });

    this.clearSelection();
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

  async setZoom(scale) {
    if (!this.pdf) return;
    this.clearSelection();

    // Preserve scroll position proportionally
    const container = this.el.querySelector(".pdf-viewer-pages").parentElement;
    const scrollRatio =
      container.scrollHeight > container.clientHeight
        ? container.scrollTop / (container.scrollHeight - container.clientHeight)
        : 0;

    this.currentScale = scale;

    // Re-render all pages at new scale
    const pagesContainer = this.el.querySelector(".pdf-viewer-pages");
    if (!pagesContainer) return;
    pagesContainer.innerHTML = "";
    this.pages = [];

    for (let i = 1; i <= this.pdf.numPages; i++) {
      const page = await this.pdf.getPage(i);
      const pageWrapper = this.createPageElement(page, i, pagesContainer);
      this.pages.push(pageWrapper);
    }

    // Restore scroll position
    requestAnimationFrame(() => {
      const maxScroll = container.scrollHeight - container.clientHeight;
      container.scrollTop = scrollRatio * maxScroll;
    });
  },

  destroyPdf() {
    this.clearSelection();
    if (this.pdf) {
      this.pdf.destroy();
      this.pdf = null;
    }
    this.pages = [];
    const container = this.el.querySelector(".pdf-viewer-pages");
    if (container) container.innerHTML = "";
  },

  destroyed() {
    this.destroyPdf();
  },
};

export default PdfViewer;
