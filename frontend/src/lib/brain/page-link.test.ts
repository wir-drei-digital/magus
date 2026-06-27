// @vitest-environment jsdom
// page-link.js imports tippy.js (DOM-dependent), so this needs a window.
import { describe, expect, it, vi } from 'vitest';
import { createPageRefDecoPlugin } from './page-link';

/** Minimal ProseMirror EditorView stand-in for driving the plugin's view.update. */
function fakeView() {
	const tr = { setMeta: () => tr };
	return { state: { tr }, dispatch: vi.fn() };
}

/** page-link.js is a @ts-nocheck vendored module and ProseMirror's PluginView
 *  types are awkward to satisfy with a stub, so drive the view through `any`. */
function pluginView(getPages: () => { id: string; title: string }[]) {
	// eslint-disable-next-line @typescript-eslint/no-explicit-any
	return (createPageRefDecoPlugin(getPages, null) as any).spec.view();
}

describe('page-link decoration plugin view', () => {
	it('does NOT dispatch a rebuild when the page titles are unchanged', () => {
		// The host passes a getter that returns a NEW array each call (pages.map(...)).
		// A reference comparison would see "changed" every time and dispatch forever
		// (each dispatch re-runs the plugin view → infinite recursion → stack overflow).
		const getPages = () => [
			{ id: '1', title: 'Alpha' },
			{ id: '2', title: 'Beta' }
		];
		const { update } = pluginView(getPages);
		const view = fakeView();

		update(view);
		update(view);

		expect(view.dispatch).not.toHaveBeenCalled();
	});

	it('dispatches a rebuild exactly once when a page title actually changes', () => {
		let pages = [{ id: '1', title: 'Alpha' }];
		const getPages = () => pages.map((p) => ({ ...p })); // fresh array each call
		const { update } = pluginView(getPages);
		const view = fakeView();

		update(view); // titles unchanged since creation → no dispatch
		expect(view.dispatch).not.toHaveBeenCalled();

		pages = [
			{ id: '1', title: 'Alpha' },
			{ id: '2', title: 'Beta' }
		];
		update(view); // a title appeared → one rebuild
		update(view); // stable again → no further dispatch
		expect(view.dispatch).toHaveBeenCalledTimes(1);
	});
});
