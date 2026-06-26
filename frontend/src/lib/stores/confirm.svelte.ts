/**
 * Promise-based confirmation, a branded replacement for `window.confirm`.
 *
 * Call `confirmAction({ title, ... })` and await the boolean. A single
 * `<ConfirmDialog />` host (mounted in the root layout) renders the request and
 * resolves the promise. This standardizes destructive confirms across the app
 * (the alternative — a native OS dialog — breaks the visual language and varies
 * by platform).
 */
export type ConfirmOptions = {
	title: string;
	description?: string;
	confirmLabel?: string;
	cancelLabel?: string;
	/** Style the confirm button as destructive. Defaults to true (these are guards). */
	destructive?: boolean;
};

type PendingConfirm = ConfirmOptions & { resolve: (value: boolean) => void };

class ConfirmStore {
	pending = $state<PendingConfirm | null>(null);

	ask(options: ConfirmOptions): Promise<boolean> {
		// A new request supersedes any in-flight one (resolve the old as cancelled).
		this.pending?.resolve(false);
		return new Promise<boolean>((resolve) => {
			this.pending = { destructive: true, ...options, resolve };
		});
	}

	#settle(value: boolean): void {
		const current = this.pending;
		this.pending = null;
		current?.resolve(value);
	}

	confirm(): void {
		this.#settle(true);
	}

	cancel(): void {
		this.#settle(false);
	}
}

export const confirmStore = new ConfirmStore();

/** Awaitable confirm. Resolves true when the user confirms, false otherwise. */
export const confirmAction = (options: ConfirmOptions): Promise<boolean> =>
	confirmStore.ask(options);
