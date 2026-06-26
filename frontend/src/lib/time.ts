/**
 * Timestamp formats used across the workbench (pure, unit-tested):
 *  - compact:  nav rows           — "3d", "1w", "now"
 *  - relative: header subtitles   — "2d ago", "just now"
 *  - message:  bubble footers     — same week "Tuesday at 21:14",
 *                                   older "May 27 at 12:23"
 */

const MINUTE = 60_000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;
const WEEK = 7 * DAY;

export function compactTime(iso: string, now: Date = new Date()): string {
	const delta = now.getTime() - new Date(iso).getTime();
	if (delta < MINUTE) return 'now';
	if (delta < HOUR) return `${Math.floor(delta / MINUTE)}m`;
	if (delta < DAY) return `${Math.floor(delta / HOUR)}h`;
	if (delta < WEEK) return `${Math.floor(delta / DAY)}d`;
	if (delta < 5 * WEEK) return `${Math.floor(delta / WEEK)}w`;
	return `${Math.floor(delta / (30 * DAY))}mo`;
}

export function relativeTime(iso: string, now: Date = new Date()): string {
	const delta = now.getTime() - new Date(iso).getTime();
	if (delta < MINUTE) return 'just now';
	if (delta < HOUR) return `${Math.floor(delta / MINUTE)}m ago`;
	if (delta < DAY) return `${Math.floor(delta / HOUR)}h ago`;
	if (delta < WEEK) return `${Math.floor(delta / DAY)}d ago`;
	if (delta < 5 * WEEK) return `${Math.floor(delta / WEEK)}w ago`;
	return `${Math.floor(delta / (30 * DAY))}mo ago`;
}

export function messageTime(iso: string, now: Date = new Date()): string {
	const date = new Date(iso);
	const time = date.toLocaleTimeString(undefined, {
		hour: '2-digit',
		minute: '2-digit',
		hour12: false
	});

	if (now.getTime() - date.getTime() < WEEK) {
		const weekday = date.toLocaleDateString('en-US', { weekday: 'long' });
		return `${weekday} at ${time}`;
	}

	const day = date.toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
	return `${day} at ${time}`;
}
