/**
 * Typed styling for non-tool system-event messages, ported from the workbench
 * events.ex detect_event_style / event_icon_name. Text-based classification
 * (the SPA message RPC does not yet expose metadata, so wakeup-stage / job /
 * draft styling is deferred — see magus-xzkv).
 */
export type EventSeverity = 'warning' | 'error' | 'info';
export type EventIconKey = 'warning' | 'error' | 'search' | 'note' | 'dice' | 'info';

export type EventVisual = { severity: EventSeverity; icon: EventIconKey };

function includesAny(haystack: string, needles: string[]): boolean {
	return needles.some((needle) => haystack.includes(needle));
}

/** Classify an event by its text content, mirroring detect_event_style. */
export function eventSeverity(text: string): EventSeverity {
	if (typeof text !== 'string') return 'info';
	if (includesAny(text, ['limit', 'exceeded', 'reached your', 'storage'])) return 'warning';
	if (includesAny(text, ['error', 'Error', 'failed', 'Failed'])) return 'error';
	if (includesAny(text, ['timeout', 'Timeout', 'closed', 'Connection'])) return 'error';
	return 'info';
}

/** Severity + an icon key for an event message (event_display_info parity). */
export function eventVisual(text: string): EventVisual {
	const severity = eventSeverity(text);
	if (severity !== 'info') return { severity, icon: severity };

	// Info events pick an icon from their content (event_icon_name).
	let icon: EventIconKey = 'info';
	if (typeof text === 'string') {
		if (text.includes('Search')) icon = 'search';
		else if (text.includes('Note')) icon = 'note';
		else if (text.includes('Dice')) icon = 'dice';
	}
	return { severity: 'info', icon };
}
