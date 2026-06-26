/**
 * Send-time guards for the composer, ported from the workbench
 * chat_input_component has_modality_mismatch?. Pure + tested.
 */
import type { ModelSummary, UploadedFile } from '$lib/ash/api';

/** True when any attachment is an image. */
export function hasImageAttachment(files: UploadedFile[]): boolean {
	return files.some((file) => file.type === 'image' || (file.mimeType ?? '').startsWith('image/'));
}

/**
 * True when an image is attached but the selected model cannot accept image
 * input (its input modalities lack "image"). Auto (no model) never mismatches —
 * the router picks a capable model.
 */
export function imageModalityMismatch(files: UploadedFile[], model: ModelSummary | null): boolean {
	if (!model || !hasImageAttachment(files)) return false;
	return !(model.inputModalities ?? ['text']).includes('image');
}
