import { describe, expect, it } from 'vitest';
import { draftEventLabel, jobTriggerInfo, selectionIndicators, wakeupInfo } from './message-meta';

describe('selectionIndicators', () => {
	it('returns [] for missing/empty metadata', () => {
		expect(selectionIndicators(null)).toEqual([]);
		expect(selectionIndicators({})).toEqual([]);
	});

	it('builds a draft chip with title + hint line', () => {
		expect(
			selectionIndicators({
				draft_selection: { text: 'the body', draft_title: 'Memo', hint_line: 12 }
			})
		).toEqual([{ icon: 'draft', label: 'Memo ~line 12', text: 'the body' }]);
	});

	it('skips a draft selection with no text', () => {
		expect(selectionIndicators({ draft_selection: { draft_title: 'Memo' } })).toEqual([]);
	});

	it('builds a pdf chip (text → label+text, no text → filename chip)', () => {
		expect(
			selectionIndicators({ pdf_selection: { text: 'quoted', filename: 'spec.pdf', page: 3 } })
		).toEqual([{ icon: 'pdf', label: 'spec.pdf p.3', text: 'quoted' }]);
		expect(selectionIndicators({ pdf_selection: { filename: 'spec.pdf' } })).toEqual([
			{ icon: 'pdf', label: null, text: 'spec.pdf' }
		]);
	});

	it('builds service + quote chips and preserves order', () => {
		const result = selectionIndicators({
			service_selection: { service_name: 'web app' },
			message_selections: [{ text: 'first' }, { text: 'second' }]
		});
		expect(result).toEqual([
			{ icon: 'service', label: null, text: 'web app' },
			{ icon: 'quote', label: null, text: 'first' },
			{ icon: 'quote', label: null, text: 'second' }
		]);
	});

	it('truncates long selection text to 60 chars + ellipsis', () => {
		const long = 'x'.repeat(80);
		const [chip] = selectionIndicators({ message_selections: [{ text: long }] });
		expect(chip.text).toHaveLength(61);
		expect(chip.text.endsWith('…')).toBe(true);
	});
});

describe('wakeupInfo', () => {
	it('returns null without a wakeup_run_id', () => {
		expect(wakeupInfo({})).toBeNull();
		expect(wakeupInfo({ wakeup_run_id: '' })).toBeNull();
	});

	it('reads stage + source with defaults', () => {
		expect(wakeupInfo({ wakeup_run_id: 'r1' })).toEqual({ stage: 'running', source: 'heartbeat' });
		expect(
			wakeupInfo({ wakeup_run_id: 'r1', wakeup_stage: 'complete', source: 'manual_trigger' })
		).toEqual({ stage: 'complete', source: 'manual_trigger' });
	});
});

describe('jobTriggerInfo', () => {
	it('reads job + memory name with a default job name', () => {
		expect(jobTriggerInfo({ job_name: 'Daily digest', memory_name: 'notes' })).toEqual({
			jobName: 'Daily digest',
			memoryName: 'notes'
		});
		expect(jobTriggerInfo({})).toEqual({ jobName: 'Scheduled Job', memoryName: null });
	});
});

describe('draftEventLabel', () => {
	it('maps draft_action to a label', () => {
		expect(draftEventLabel({ draft_action: 'review' })).toBe('Draft Review');
		expect(draftEventLabel({ draft_action: 'approve' })).toBe('Draft Export');
		expect(draftEventLabel({ draft_action: 'other' })).toBe('Draft Action');
		expect(draftEventLabel({})).toBe('Draft Review');
	});
});
