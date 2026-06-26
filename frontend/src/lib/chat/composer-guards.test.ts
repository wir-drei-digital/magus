import { describe, expect, it } from 'vitest';
import type { ModelSummary, UploadedFile } from '$lib/ash/api';
import { hasImageAttachment, imageModalityMismatch } from './composer-guards';

const file = (overrides: Partial<UploadedFile>): UploadedFile => ({
	id: 'f1',
	name: 'a',
	type: 'file',
	mimeType: 'application/pdf',
	fileSize: 1,
	...overrides
});

const model = (inputModalities: string[] | null): ModelSummary =>
	({ id: 'm1', name: 'M', inputModalities }) as ModelSummary;

describe('hasImageAttachment', () => {
	it('detects images by type or mime', () => {
		expect(hasImageAttachment([file({ type: 'image' })])).toBe(true);
		expect(hasImageAttachment([file({ type: 'file', mimeType: 'image/png' })])).toBe(true);
		expect(hasImageAttachment([file({})])).toBe(false);
		expect(hasImageAttachment([])).toBe(false);
	});
});

describe('imageModalityMismatch', () => {
	it('blocks an image attachment for a text-only model', () => {
		expect(imageModalityMismatch([file({ type: 'image' })], model(['text']))).toBe(true);
	});

	it('allows an image for an image-capable model', () => {
		expect(imageModalityMismatch([file({ type: 'image' })], model(['text', 'image']))).toBe(false);
	});

	it('never mismatches without an image or with Auto (no model)', () => {
		expect(imageModalityMismatch([file({})], model(['text']))).toBe(false);
		expect(imageModalityMismatch([file({ type: 'image' })], null)).toBe(false);
	});

	it('treats null modalities as text-only', () => {
		expect(imageModalityMismatch([file({ type: 'image' })], model(null))).toBe(true);
	});
});
