import { describe, expect, it } from 'vitest';
import { toTemplate, parseTemplateParam, type ModelTemplate } from './model-template';

describe('toTemplate', () => {
	it('maps name and derives a slug model id from the name (key is not exposed)', () => {
		const t = toTemplate({
			name: 'Claude Sonnet 4',
			contextWindow: 200000,
			inputCost: '$3',
			outputCost: '$15'
		});
		expect(t.name).toBe('Claude Sonnet 4');
		expect(t.modelId).toBe('claude-sonnet-4');
		expect(t.contextWindow).toBe(200000);
		expect(t.inputCost).toBe(3);
		expect(t.outputCost).toBe(15);
	});

	it('parses fractional and prefixed cost display strings', () => {
		const t = toTemplate({
			name: 'GPT-4o mini',
			inputCost: '$0.15',
			outputCost: '$0.60 / 1M'
		});
		expect(t.inputCost).toBe(0.15);
		expect(t.outputCost).toBe(0.6);
	});

	it('omits missing context and cost fields rather than sending zeros', () => {
		const t = toTemplate({
			name: 'Some Model',
			contextWindow: null,
			inputCost: null,
			outputCost: null
		});
		expect(t.name).toBe('Some Model');
		expect(t.modelId).toBe('some-model');
		expect('contextWindow' in t).toBe(false);
		expect('inputCost' in t).toBe(false);
		expect('outputCost' in t).toBe(false);
	});

	it('omits costs that do not contain a parseable number', () => {
		const t = toTemplate({
			name: 'Free Model',
			inputCost: 'Free',
			outputCost: 'n/a'
		});
		expect('inputCost' in t).toBe(false);
		expect('outputCost' in t).toBe(false);
	});

	it('never emits a zero context window', () => {
		const t = toTemplate({ name: 'Zero Ctx', contextWindow: 0 });
		expect('contextWindow' in t).toBe(false);
	});

	it('slugifies punctuation and collapses runs of separators', () => {
		expect(toTemplate({ name: 'Llama 3.1 (405B)' }).modelId).toBe('llama-3-1-405b');
		expect(toTemplate({ name: '  Spaced   Name  ' }).modelId).toBe('spaced-name');
	});
});

describe('parseTemplateParam', () => {
	it('round-trips a template through the URL param encoding', () => {
		const template: ModelTemplate = {
			name: 'Claude Sonnet 4',
			modelId: 'claude-sonnet-4',
			contextWindow: 200000,
			inputCost: 3,
			outputCost: 15
		};
		const raw = encodeURIComponent(JSON.stringify(template));
		expect(parseTemplateParam(raw)).toEqual(template);
	});

	it('accepts an already-decoded JSON string', () => {
		const template: ModelTemplate = { name: 'X', modelId: 'x' };
		expect(parseTemplateParam(JSON.stringify(template))).toEqual(template);
	});

	it('returns null for null / empty input', () => {
		expect(parseTemplateParam(null)).toBeNull();
		expect(parseTemplateParam('')).toBeNull();
	});

	it('returns null on malformed JSON without throwing', () => {
		expect(parseTemplateParam('{not json')).toBeNull();
		expect(parseTemplateParam('%%%')).toBeNull();
		expect(parseTemplateParam('42')).toBeNull();
		expect(parseTemplateParam('"a string"')).toBeNull();
		expect(parseTemplateParam('null')).toBeNull();
	});

	it('rejects objects missing required name / modelId', () => {
		expect(parseTemplateParam(JSON.stringify({ name: 'only name' }))).toBeNull();
		expect(parseTemplateParam(JSON.stringify({ modelId: 'only-id' }))).toBeNull();
		expect(parseTemplateParam(JSON.stringify({}))).toBeNull();
	});

	it('drops non-numeric optional fields instead of failing', () => {
		const raw = JSON.stringify({
			name: 'X',
			modelId: 'x',
			contextWindow: 'lots',
			inputCost: null,
			outputCost: 2
		});
		expect(parseTemplateParam(raw)).toEqual({ name: 'X', modelId: 'x', outputCost: 2 });
	});
});
