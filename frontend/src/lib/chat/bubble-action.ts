/**
 * Maps a tiptap bubble-menu Ask/Refine event into the text to drop into a chat
 * composer. "ask" forwards the raw selection; "refine" prefixes the typed
 * instruction (classic ask/refine transport parity). Returns null when the
 * selection is empty.
 */
export function bubbleSelectionText(
	event: string,
	payload: Record<string, unknown>
): string | null {
	const selection = typeof payload.text === 'string' ? payload.text.trim() : '';
	if (!selection) return null;
	const instruction = typeof payload.instruction === 'string' ? payload.instruction.trim() : '';
	return event === 'refine' && instruction ? `${instruction}:\n\n${selection}` : selection;
}
