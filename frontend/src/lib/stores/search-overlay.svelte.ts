/**
 * Open state for the global search overlay. Lives in a store (not the nav pane)
 * so the overlay can render at the layout root, outside the left rail's
 * `translate-x` transform — a transformed ancestor becomes the containing block
 * for `position: fixed` children, which would otherwise clamp the full-screen
 * overlay to the rail's width.
 */
class SearchOverlayState {
	open = $state(false);
}

export const searchOverlay = new SearchOverlayState();
