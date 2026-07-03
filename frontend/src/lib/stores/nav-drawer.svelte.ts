/**
 * Mobile nav drawer state, shared between the root layout (which renders the
 * slide-in drawer) and the inline menu buttons that pane headers render
 * below md. Desktop ignores it (the rail is statically positioned at md+).
 */
class NavDrawer {
	open = $state(false);
}

export const navDrawer = new NavDrawer();
