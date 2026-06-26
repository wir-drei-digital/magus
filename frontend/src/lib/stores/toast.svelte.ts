/**
 * Lightweight transient toasts, primarily for "Undo" after a destructive action.
 *
 * Call `toast('Message', { action: { label: 'Undo', run } })`. A single
 * `<ToastHost />` (mounted in the root layout) renders the stack and auto-dismisses.
 */
export type ToastAction = { label: string; run: () => void };
export type Toast = { id: number; message: string; action?: ToastAction };

class ToastStore {
	toasts = $state<Toast[]>([]);
	#seq = 0;
	#timers = new Map<number, ReturnType<typeof setTimeout>>();

	show(message: string, options: { action?: ToastAction; duration?: number } = {}): number {
		const id = ++this.#seq;
		this.toasts = [...this.toasts, { id, message, action: options.action }];
		// Undo affordances need a generous window; plain notices clear sooner.
		const duration = options.duration ?? (options.action ? 8000 : 4000);
		this.#timers.set(
			id,
			setTimeout(() => this.dismiss(id), duration)
		);
		return id;
	}

	dismiss(id: number): void {
		const timer = this.#timers.get(id);
		if (timer) {
			clearTimeout(timer);
			this.#timers.delete(id);
		}
		this.toasts = this.toasts.filter((toast) => toast.id !== id);
	}

	runAction(id: number): void {
		const toast = this.toasts.find((entry) => entry.id === id);
		toast?.action?.run();
		this.dismiss(id);
	}
}

export const toastStore = new ToastStore();

export const toast = (
	message: string,
	options?: { action?: ToastAction; duration?: number }
): number => toastStore.show(message, options);
