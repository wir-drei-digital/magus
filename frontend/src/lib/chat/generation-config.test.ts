import { describe, expect, it } from 'vitest';
import {
	imageConfigSummary,
	imageGenSettings,
	videoConfigSummary,
	videoGenSettings
} from './generation-config';

describe('imageGenSettings', () => {
	it('defaults to 1:1 / 1K for empty/invalid input', () => {
		expect(imageGenSettings(null)).toEqual({ aspect_ratio: '1:1', image_size: '1K' });
		expect(imageGenSettings({ aspect_ratio: 'bogus', image_size: '9K' })).toEqual({
			aspect_ratio: '1:1',
			image_size: '1K'
		});
	});

	it('keeps valid stored values', () => {
		expect(imageGenSettings({ aspect_ratio: '16:9', image_size: '4K' })).toEqual({
			aspect_ratio: '16:9',
			image_size: '4K'
		});
	});
});

describe('videoGenSettings', () => {
	it('defaults to first-of-list and audio on', () => {
		expect(videoGenSettings(null)).toEqual({
			aspect_ratio: '16:9',
			duration: '2',
			resolution: 'auto',
			generate_audio: true
		});
	});

	it('respects generate_audio false and valid values', () => {
		expect(
			videoGenSettings({
				aspect_ratio: '9:16',
				duration: '8',
				resolution: '1080p',
				generate_audio: false
			})
		).toEqual({ aspect_ratio: '9:16', duration: '8', resolution: '1080p', generate_audio: false });
	});
});

describe('summaries', () => {
	it('formats the image summary', () => {
		expect(imageConfigSummary({ aspect_ratio: '4:3', image_size: '2K' })).toBe('4:3 / 2K');
	});

	it('formats the video summary with an audio glyph when enabled', () => {
		expect(videoConfigSummary({ aspect_ratio: '16:9', duration: '5', resolution: '720p' })).toBe(
			'16:9 · 5s · 720p · 🔊'
		);
		expect(
			videoConfigSummary({
				aspect_ratio: '1:1',
				duration: '3',
				resolution: 'auto',
				generate_audio: false
			})
		).toBe('1:1 · 3s · auto');
	});
});
