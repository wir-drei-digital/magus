import type { TabSession } from '$lib/ash/api';

type Mode = TabSession['mode'];

const MODE_SEGMENTS: Array<[Mode, string]> = [
	['brain', '/brain'],
	['files', '/files'],
	['library', '/library'],
	// Legacy trees redirect to /library; don't flash the chat nav meanwhile.
	['library', '/prompts'],
	['library', '/skills'],
	['agents', '/agents']
];

/**
 * Best-guess workbench mode from the current URL — the pre-session fallback
 * so reloading on a brain page doesn't flash the chat nav while the
 * TabSession round trip is in flight. The session's mode wins once loaded
 * (the mode strip can intentionally diverge from the open view).
 */
export function modeFromPath(pathname: string): Mode {
	for (const [mode, segment] of MODE_SEGMENTS) {
		if (pathname.includes(segment)) return mode;
	}
	return 'chat';
}
