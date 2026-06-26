/**
 * Image/video generation config, mirroring Magus.Agents.ImageGenerationConfig
 * and VideoGenerationConfig (the backend sanitizes to these same allowed
 * values). Pure + tested; the dropdown UI lives in generation-config.svelte.
 *
 * Per-model option overrides (some models constrain the allowed ratios /
 * durations) are not modeled here — like the workbench's no-model-options
 * fallback, the SPA offers the full lists.
 */
export const IMAGE_ASPECT_RATIOS = [
	'1:1',
	'2:3',
	'3:2',
	'3:4',
	'4:3',
	'4:5',
	'5:4',
	'9:16',
	'16:9',
	'21:9'
];
export const IMAGE_SIZES = ['1K', '2K', '4K'];

export const VIDEO_ASPECT_RATIOS = ['16:9', '9:16', '4:3', '1:1', '3:4', '21:9', '9:21'];
export const VIDEO_DURATIONS = ['2', '3', '4', '5', '6', '8', '10', '12', '16', '20'];
export const VIDEO_RESOLUTIONS = ['auto', '480p', '720p', '1080p', '4k'];

export type ImageGenSettings = { aspect_ratio: string; image_size: string };
export type VideoGenSettings = {
	aspect_ratio: string;
	duration: string;
	resolution: string;
	generate_audio: boolean;
};

function asObject(value: unknown): Record<string, unknown> {
	return value && typeof value === 'object' && !Array.isArray(value)
		? (value as Record<string, unknown>)
		: {};
}

/** The stored value if it's an allowed option, else the default. */
function pick(value: unknown, allowed: string[], fallback: string): string {
	return typeof value === 'string' && allowed.includes(value) ? value : fallback;
}

/** Resolved image settings (stored value validated against the allowed lists). */
export function imageGenSettings(raw: unknown): ImageGenSettings {
	const o = asObject(raw);
	return {
		aspect_ratio: pick(o.aspect_ratio, IMAGE_ASPECT_RATIOS, '1:1'),
		image_size: pick(o.image_size, IMAGE_SIZES, '1K')
	};
}

/** Resolved video settings (generate_audio defaults to true, like the workbench). */
export function videoGenSettings(raw: unknown): VideoGenSettings {
	const o = asObject(raw);
	return {
		aspect_ratio: pick(o.aspect_ratio, VIDEO_ASPECT_RATIOS, VIDEO_ASPECT_RATIOS[0]),
		duration: pick(o.duration, VIDEO_DURATIONS, VIDEO_DURATIONS[0]),
		resolution: pick(o.resolution, VIDEO_RESOLUTIONS, VIDEO_RESOLUTIONS[0]),
		generate_audio: o.generate_audio !== false
	};
}

/** Compact summary for the trigger button, e.g. "1:1 / 1K". */
export function imageConfigSummary(raw: unknown): string {
	const s = imageGenSettings(raw);
	return `${s.aspect_ratio} / ${s.image_size}`;
}

/** Compact summary, e.g. "16:9 · 2s · auto · 🔊". */
export function videoConfigSummary(raw: unknown): string {
	const s = videoGenSettings(raw);
	const parts = [s.aspect_ratio, `${s.duration}s`, s.resolution];
	if (s.generate_audio) parts.push('🔊');
	return parts.join(' · ');
}
