<script lang="ts">
	/**
	 * PDF.js viewer with rectangle selection, ported from the classic
	 * PdfViewer hook (assets/js/pdf_viewer.js): pages render onto canvases,
	 * a transparent overlay per page lets the user drag a selection box, and
	 * "Ask" crops the region straight out of the canvas (JPEG data URL) plus
	 * extracts the text inside the box via PDF.js textContent. The result goes
	 * to `onSelection`, which the companion pins as a composer context pill.
	 *
	 * Page/selection DOM is managed imperatively (as in the classic hook):
	 * PDF.js renders outside Svelte's reactivity anyway, and the selection
	 * rect/Ask button live inside per-page overlays created at render time.
	 */
	import * as pdfjsLib from 'pdfjs-dist';
	import type { PDFDocumentProxy, PDFPageProxy } from 'pdfjs-dist';
	import workerUrl from 'pdfjs-dist/build/pdf.worker.min.mjs?url';

	pdfjsLib.GlobalWorkerOptions.workerSrc = workerUrl;

	/** ~2MB limit for the base64 payload (classic MAX_IMAGE_BYTES). */
	const MAX_IMAGE_BYTES = 2_000_000;

	let {
		url,
		scale = 1,
		onSelection
	}: {
		url: string;
		/** 1 = 100% (1 PDF point per CSS pixel). */
		scale?: number;
		/** Region capture: cropped screenshot + extracted text + page number. */
		onSelection?: (selection: { image: string; text: string; page: number }) => void;
	} = $props();

	let scroller = $state<HTMLDivElement | null>(null);
	let pagesEl = $state<HTMLDivElement | null>(null);
	let loadError = $state<string | null>(null);
	let loading = $state(true);

	type PageEntry = {
		canvas: HTMLCanvasElement;
		overlay: HTMLDivElement;
		page: PDFPageProxy;
		pageNumber: number;
	};

	let pdf: PDFDocumentProxy | null = null;
	let pages: PageEntry[] = [];
	let selection: {
		x: number;
		y: number;
		w: number;
		h: number;
		pageNumber: number;
		overlay: HTMLDivElement;
		canvas: HTMLCanvasElement;
	} | null = null;
	let selectionRect: HTMLDivElement | null = null;
	let askButton: HTMLButtonElement | null = null;

	// Guards against async races: only the latest load/render applies its DOM.
	let renderToken = 0;

	$effect(() => {
		const documentUrl = url;
		const container = pagesEl;
		if (!container) return;

		const token = ++renderToken;
		loadError = null;
		loading = true;

		void (async () => {
			try {
				const loaded = await pdfjsLib.getDocument(documentUrl).promise;
				if (token !== renderToken) {
					void loaded.destroy();
					return;
				}
				pdf = loaded;
				await renderPages(token);
			} catch (error) {
				if (token !== renderToken) return;
				loadError = error instanceof Error ? error.message : 'The PDF could not be loaded.';
				loading = false;
			}
		})();

		return () => {
			renderToken += 1;
			clearSelection();
			void pdf?.destroy();
			pdf = null;
			pages = [];
		};
	});

	// Zoom re-render: preserve the scroll position proportionally (classic setZoom).
	let renderedScale = 1;
	$effect(() => {
		const nextScale = scale;
		if (!pdf || nextScale === renderedScale) return;
		const token = ++renderToken;
		const ratio =
			scroller && scroller.scrollHeight > scroller.clientHeight
				? scroller.scrollTop / (scroller.scrollHeight - scroller.clientHeight)
				: 0;
		void renderPages(token).then(() => {
			if (token !== renderToken) return;
			requestAnimationFrame(() => {
				if (!scroller) return;
				scroller.scrollTop = ratio * (scroller.scrollHeight - scroller.clientHeight);
			});
		});
	});

	async function renderPages(token: number) {
		const container = pagesEl;
		if (!pdf || !container) return;

		clearSelection();
		container.innerHTML = '';
		pages = [];
		renderedScale = scale;

		for (let i = 1; i <= pdf.numPages; i++) {
			const page = await pdf.getPage(i);
			if (token !== renderToken) return;
			pages.push(createPageElement(page, i, container));
		}
		loading = false;
	}

	function createPageElement(
		page: PDFPageProxy,
		pageNumber: number,
		container: HTMLElement
	): PageEntry {
		const cssViewport = page.getViewport({ scale });
		// Render at up to 2x for crisp text on HiDPI displays.
		const dpr = Math.min(window.devicePixelRatio || 1, 2);
		const renderViewport = page.getViewport({ scale: scale * dpr });

		const wrapper = document.createElement('div');
		wrapper.className = 'pdf-page-wrapper';
		wrapper.dataset.pageNumber = String(pageNumber);
		wrapper.style.position = 'relative';
		// At default scale or below, fit to container width; above, allow overflow.
		wrapper.style.width = `${cssViewport.width}px`;
		if (scale <= 1) wrapper.style.maxWidth = '100%';

		const canvas = document.createElement('canvas');
		canvas.className = 'pdf-page-canvas';
		canvas.width = renderViewport.width;
		canvas.height = renderViewport.height;
		canvas.style.width = '100%';
		canvas.style.height = 'auto';
		canvas.style.display = 'block';

		const ctx = canvas.getContext('2d');
		if (ctx) void page.render({ canvasContext: ctx, viewport: renderViewport });

		wrapper.appendChild(canvas);

		const overlay = document.createElement('div');
		if (onSelection) {
			// Transparent selection layer; only wired when a composer can receive
			// the capture.
			overlay.className = 'pdf-selection-overlay';
			overlay.style.position = 'absolute';
			overlay.style.inset = '0';
			overlay.style.cursor = 'crosshair';
			overlay.style.zIndex = '1';
			setupSelectionHandlers(overlay, canvas, pageNumber);
			wrapper.appendChild(overlay);
		}

		container.appendChild(wrapper);
		return { canvas, overlay, page, pageNumber };
	}

	function setupSelectionHandlers(
		overlay: HTMLDivElement,
		canvas: HTMLCanvasElement,
		pageNumber: number
	) {
		let selecting = false;
		let startX = 0;
		let startY = 0;

		const begin = (clientX: number, clientY: number) => {
			clearSelection();
			selecting = true;
			const rect = overlay.getBoundingClientRect();
			startX = clientX - rect.left;
			startY = clientY - rect.top;
			selectionRect = createSelectionRect(startX, startY);
			overlay.appendChild(selectionRect);
		};

		const resize = (clientX: number, clientY: number) => {
			if (!selecting || !selectionRect) return;
			const rect = overlay.getBoundingClientRect();
			const currentX = clientX - rect.left;
			const currentY = clientY - rect.top;
			selectionRect.style.left = `${Math.min(startX, currentX)}px`;
			selectionRect.style.top = `${Math.min(startY, currentY)}px`;
			selectionRect.style.width = `${Math.abs(currentX - startX)}px`;
			selectionRect.style.height = `${Math.abs(currentY - startY)}px`;
		};

		const finish = (clientX: number, clientY: number) => {
			if (!selecting || !selectionRect) return;
			selecting = false;
			const rect = overlay.getBoundingClientRect();
			const currentX = clientX - rect.left;
			const currentY = clientY - rect.top;
			const x = Math.min(startX, currentX);
			const y = Math.min(startY, currentY);
			const w = Math.abs(currentX - startX);
			const h = Math.abs(currentY - startY);

			// Minimum selection size (10px) — a plain click clears instead.
			if (w < 10 || h < 10) {
				clearSelection();
				return;
			}
			selection = { x, y, w, h, pageNumber, overlay, canvas };
			showAskButton(overlay, x, y, w, h);
		};

		overlay.addEventListener('mousedown', (event) => {
			if ((event.target as Element).closest('.pdf-ask-button')) return;
			begin(event.clientX, event.clientY);
		});
		overlay.addEventListener('mousemove', (event) => resize(event.clientX, event.clientY));
		overlay.addEventListener('mouseup', (event) => finish(event.clientX, event.clientY));

		overlay.addEventListener(
			'touchstart',
			(event) => {
				if (event.touches.length !== 1) return;
				if ((event.target as Element).closest('.pdf-ask-button')) return;
				begin(event.touches[0].clientX, event.touches[0].clientY);
			},
			{ passive: true }
		);
		overlay.addEventListener(
			'touchmove',
			(event) => {
				if (!selecting || event.touches.length !== 1) return;
				event.preventDefault(); // no scrolling while drawing the box
				resize(event.touches[0].clientX, event.touches[0].clientY);
			},
			{ passive: false }
		);
		overlay.addEventListener('touchend', () => {
			// touchend has no coordinates — finish from the rect's own geometry.
			if (!selecting || !selectionRect) return;
			selecting = false;
			const style = selectionRect.style;
			const x = parseFloat(style.left);
			const y = parseFloat(style.top);
			const w = parseFloat(style.width);
			const h = parseFloat(style.height);
			if (w < 10 || h < 10) {
				clearSelection();
				return;
			}
			selection = { x, y, w, h, pageNumber, overlay, canvas };
			showAskButton(overlay, x, y, w, h);
		});
	}

	function createSelectionRect(x: number, y: number): HTMLDivElement {
		const rect = document.createElement('div');
		rect.className = 'pdf-selection-rect';
		rect.style.position = 'absolute';
		rect.style.left = `${x}px`;
		rect.style.top = `${y}px`;
		rect.style.width = '0px';
		rect.style.height = '0px';
		for (const pos of ['tl', 'tr', 'bl', 'br']) {
			const corner = document.createElement('div');
			corner.className = `pdf-selection-corner pdf-selection-corner--${pos}`;
			rect.appendChild(corner);
		}
		return rect;
	}

	function showAskButton(overlay: HTMLDivElement, x: number, y: number, w: number, h: number) {
		removeAskButton();
		askButton = document.createElement('button');
		askButton.type = 'button';
		askButton.className = 'pdf-ask-button';
		askButton.dataset.testid = 'pdf-ask-selection';
		askButton.innerHTML = `<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M7.9 20A9 9 0 1 0 4 16.1L2 22Z"/></svg> Ask`;
		askButton.style.position = 'absolute';
		askButton.style.left = `${x + w + 4}px`;
		askButton.style.top = `${y + h - 32}px`;
		askButton.style.zIndex = '10';
		askButton.addEventListener('click', (event) => {
			event.stopPropagation();
			void captureAndSend();
		});
		overlay.appendChild(askButton);
	}

	async function captureAndSend() {
		if (!selection || !onSelection) return;
		const { x, y, w, h, pageNumber, overlay, canvas } = selection;

		// Map overlay CSS coordinates to canvas pixel coordinates.
		const overlayRect = overlay.getBoundingClientRect();
		const scaleX = canvas.width / overlayRect.width;
		const scaleY = canvas.height / overlayRect.height;
		const sx = Math.round(x * scaleX);
		const sy = Math.round(y * scaleY);
		const sw = Math.round(w * scaleX);
		const sh = Math.round(h * scaleY);

		const ctx = canvas.getContext('2d');
		if (!ctx) return;
		const imageData = ctx.getImageData(sx, sy, sw, sh);
		const tempCanvas = document.createElement('canvas');
		tempCanvas.width = sw;
		tempCanvas.height = sh;
		tempCanvas.getContext('2d')?.putImageData(imageData, 0, 0);

		let base64 = tempCanvas.toDataURL('image/jpeg', 0.85);
		// Enforce the payload limit — downscale if too large.
		if (base64.length > MAX_IMAGE_BYTES) {
			const ratio = Math.sqrt(MAX_IMAGE_BYTES / base64.length);
			const smallCanvas = document.createElement('canvas');
			smallCanvas.width = Math.round(sw * ratio);
			smallCanvas.height = Math.round(sh * ratio);
			smallCanvas
				.getContext('2d')
				?.drawImage(tempCanvas, 0, 0, smallCanvas.width, smallCanvas.height);
			base64 = smallCanvas.toDataURL('image/jpeg', 0.75);
		}

		// Extract the text inside the box. Overlay coords are CSS pixels; text
		// items are in viewport space — rescale via the overlay/viewport ratio.
		let extractedText = '';
		try {
			const entry = pages.find((candidate) => candidate.pageNumber === pageNumber);
			if (entry) {
				const textContent = await entry.page.getTextContent();
				const viewport = entry.page.getViewport({ scale: renderedScale });
				const ovScale = viewport.width / overlayRect.width;
				const selX = x * ovScale;
				const selY = y * ovScale;
				const selW = w * ovScale;
				const selH = h * ovScale;

				extractedText = textContent.items
					.filter(
						(item): item is import('pdfjs-dist/types/src/display/api').TextItem => 'str' in item
					)
					.filter((item) => {
						const tx = item.transform[4];
						// PDF y-coordinates are bottom-up; the viewport is top-down.
						const ty = viewport.height - item.transform[5];
						const tw = item.width;
						const th = item.height || 12;
						return tx < selX + selW && tx + tw > selX && ty < selY + selH && ty + th > selY;
					})
					.map((item) => item.str)
					.join(' ')
					.trim();
			}
		} catch {
			// Text extraction is best-effort; the screenshot alone is still useful.
		}

		onSelection({ image: base64, text: extractedText, page: pageNumber });
		clearSelection();
	}

	function clearSelection() {
		selectionRect?.remove();
		selectionRect = null;
		removeAskButton();
		selection = null;
	}

	function removeAskButton() {
		askButton?.remove();
		askButton = null;
	}
</script>

<div
	bind:this={scroller}
	class="wb-scroll min-h-0 w-full flex-1 overflow-auto bg-muted/30 p-3"
	data-testid="pdf-viewer"
>
	{#if loadError}
		<p class="p-4 text-sm text-destructive">{loadError}</p>
	{:else if loading}
		<div class="space-y-3">
			<div class="mx-auto aspect-[3/4] w-full max-w-lg animate-pulse rounded bg-muted"></div>
		</div>
	{/if}
	<div bind:this={pagesEl} class="mx-auto flex w-fit max-w-full flex-col items-center gap-3"></div>
</div>

<style>
	/* The page/selection elements are created imperatively (PDF.js renders
	   outside Svelte), so their styles must be :global. Ported from the classic
	   assets/css/pdf_viewer.css onto the SPA tokens. */
	:global(.pdf-page-wrapper) {
		box-shadow: 0 2px 8px oklch(0 0 0 / 0.15);
		border-radius: 0.25rem;
		overflow: hidden;
		background: white;
	}

	/* Selection rectangle — double stroke for contrast on any background. */
	:global(.pdf-selection-rect) {
		border: 2px solid white;
		outline: 2px solid var(--primary);
		background: oklch(from var(--primary) l c h / 0.1);
		pointer-events: none;
		border-radius: 2px;
	}

	:global(.pdf-selection-corner) {
		position: absolute;
		width: 10px;
		height: 10px;
		background: white;
		border: 2px solid var(--primary);
		border-radius: 2px;
		pointer-events: none;
	}

	:global(.pdf-selection-corner--tl) {
		top: -5px;
		left: -5px;
	}
	:global(.pdf-selection-corner--tr) {
		top: -5px;
		right: -5px;
	}
	:global(.pdf-selection-corner--bl) {
		bottom: -5px;
		left: -5px;
	}
	:global(.pdf-selection-corner--br) {
		bottom: -5px;
		right: -5px;
	}

	:global(.pdf-ask-button) {
		display: inline-flex;
		align-items: center;
		gap: 0.375rem;
		padding: 0.375rem 0.75rem;
		font-size: 0.8125rem;
		font-weight: 600;
		color: var(--primary-foreground);
		background: var(--primary);
		border: none;
		border-radius: 0.5rem;
		cursor: pointer;
		box-shadow: 0 2px 8px oklch(0 0 0 / 0.2);
		transition:
			background-color 0.15s ease,
			transform 0.1s ease;
		white-space: nowrap;
	}

	:global(.pdf-ask-button:hover) {
		filter: brightness(1.1);
		transform: scale(1.02);
	}

	:global(.pdf-ask-button:active) {
		transform: scale(0.98);
	}

	:global(.pdf-ask-button svg) {
		flex-shrink: 0;
	}
</style>
