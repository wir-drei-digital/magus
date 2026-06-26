/**
 * Reads structured rendering data out of a message's `metadata` map, ported
 * from the workbench message_item.ex selection_indicators + events.ex
 * wakeup/job/draft cards. Pure + tested; the components map the icon keys to
 * lucide glyphs.
 */
export type SelectionIcon = 'draft' | 'pdf' | 'service' | 'quote';
export type SelectionIndicator = { icon: SelectionIcon; label: string | null; text: string };

type Meta = Record<string, unknown> | null | undefined;

function asObject(value: unknown): Record<string, unknown> | null {
	return value && typeof value === 'object' && !Array.isArray(value)
		? (value as Record<string, unknown>)
		: null;
}

function str(value: unknown): string {
	return typeof value === 'string' ? value : '';
}

function present(value: unknown): boolean {
	return value !== undefined && value !== null && value !== '';
}

function truncate(text: string): string {
	return text.length > 60 ? `${text.slice(0, 60)}…` : text;
}

/**
 * Context the user pinned to a message (draft / pdf / service selections and
 * quoted messages), as compact chips. Mirrors selection_indicators.
 */
export function selectionIndicators(metadata: Meta): SelectionIndicator[] {
	const m = asObject(metadata);
	if (!m) return [];
	const out: SelectionIndicator[] = [];

	const draft = asObject(m.draft_selection);
	if (draft && str(draft.text) !== '') {
		const title = str(draft.draft_title) || 'Draft';
		const label = present(draft.hint_line) ? `${title} ~line ${draft.hint_line}` : title;
		out.push({ icon: 'draft', label, text: truncate(str(draft.text)) });
	}

	const pdf = asObject(m.pdf_selection);
	if (pdf) {
		const text = str(pdf.text);
		const filename = str(pdf.filename) || 'PDF';
		const label = present(pdf.page) ? `${filename} p.${pdf.page}` : filename;
		if (text !== '') out.push({ icon: 'pdf', label, text: truncate(text) });
		else out.push({ icon: 'pdf', label: null, text: label });
	}

	const service = asObject(m.service_selection);
	if (service) {
		out.push({ icon: 'service', label: null, text: str(service.service_name) || 'Service' });
	}

	const selections = Array.isArray(m.message_selections) ? m.message_selections : [];
	for (const selection of selections) {
		const s = asObject(selection);
		if (!s) continue;
		out.push({ icon: 'quote', label: null, text: truncate(str(s.text)) });
	}

	return out;
}

/** Heartbeat/manual wake-up trace info, or null for a non-wakeup event. */
export function wakeupInfo(metadata: Meta): { stage: string; source: string } | null {
	const m = asObject(metadata);
	if (!m) return null;
	const runId = m.wakeup_run_id;
	if (typeof runId !== 'string' || runId === '') return null;
	return { stage: str(m.wakeup_stage) || 'running', source: str(m.source) || 'heartbeat' };
}

/** Scheduled-job trigger label info (job_trigger_message). */
export function jobTriggerInfo(metadata: Meta): { jobName: string; memoryName: string | null } {
	const m = asObject(metadata) ?? {};
	return { jobName: str(m.job_name) || 'Scheduled Job', memoryName: str(m.memory_name) || null };
}

/** Draft-event label (draft_event_message): review / approve / other. */
export function draftEventLabel(metadata: Meta): string {
	const action = str(asObject(metadata)?.draft_action) || 'review';
	if (action === 'review') return 'Draft Review';
	if (action === 'approve') return 'Draft Export';
	return 'Draft Action';
}
