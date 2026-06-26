/**
 * Stale-while-revalidate snapshots for the workbench shell. The boot
 * waterfall (current_user → tab session + nav lists) costs several round
 * trips before anything renders; these snapshots let the stores hydrate
 * synchronously from the last known state and reconcile when fresh data
 * lands. Cleared on sign-out/expiry. Bump VERSION on shape changes — stale
 * entries are simply ignored.
 */
const VERSION = 'v1';
const PREFIX = 'magus:next:cache:';

function storage(): Storage | null {
	try {
		return typeof localStorage === 'undefined' ? null : localStorage;
	} catch {
		return null;
	}
}

export function readShellCache<T>(key: string): T | null {
	const store = storage();
	if (!store) return null;
	try {
		const raw = store.getItem(`${PREFIX}${VERSION}:${key}`);
		return raw ? (JSON.parse(raw) as T) : null;
	} catch {
		return null;
	}
}

export function writeShellCache(key: string, value: unknown): void {
	const store = storage();
	if (!store) return;
	try {
		store.setItem(`${PREFIX}${VERSION}:${key}`, JSON.stringify(value));
	} catch {
		// Quota exceeded / private mode — snapshots are best-effort.
	}
}

export function removeShellCache(key: string): void {
	const store = storage();
	if (!store) return;
	try {
		store.removeItem(`${PREFIX}${VERSION}:${key}`);
	} catch {
		// Best-effort.
	}
}

export function clearShellCache(): void {
	const store = storage();
	if (!store) return;
	try {
		for (let index = store.length - 1; index >= 0; index--) {
			const key = store.key(index);
			if (key?.startsWith(PREFIX)) store.removeItem(key);
		}
	} catch {
		// Best-effort.
	}
}
