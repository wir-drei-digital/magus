import { describe, expect, it } from 'vitest';
import {
	awaitResults,
	codeExecutionData,
	fileDownloadData,
	serviceData,
	specializedToolType,
	subAgentData,
	writeDraftData
} from './tool-render';

describe('specializedToolType', () => {
	it('maps known tool names (case-insensitive) to their renderer', () => {
		expect(specializedToolType('run_code')).toBe('sandbox');
		expect(specializedToolType('EXEC_COMMAND')).toBe('sandbox');
		expect(specializedToolType('start_service')).toBe('service');
		expect(specializedToolType('sandbox_download_file')).toBe('file_download');
		expect(specializedToolType('write_draft')).toBe('write_draft');
		expect(specializedToolType('spawn_sub_agent')).toBe('sub_agent');
		expect(specializedToolType('await_sub_agents')).toBe('await_sub_agents');
	});

	it('returns null for generic tools', () => {
		expect(specializedToolType('web_search')).toBeNull();
		expect(specializedToolType('')).toBeNull();
	});
});

describe('serviceData', () => {
	it('extracts the preview url and name', () => {
		expect(serviceData({ preview_url: '/sandbox/preview/c/', service_name: 'app' })).toEqual({
			previewUrl: '/sandbox/preview/c/',
			name: 'app',
			status: 'running'
		});
	});
});

describe('fileDownloadData', () => {
	it('extracts file metadata and formats the size', () => {
		expect(
			fileDownloadData({
				file_id: 'f1',
				filename: 'report.pdf',
				download_url: '/d/f1',
				mime_type: 'application/pdf',
				size_bytes: 2048
			})
		).toEqual({
			fileId: 'f1',
			filename: 'report.pdf',
			downloadUrl: '/d/f1',
			mimeType: 'application/pdf',
			sizeText: '2.0 KB',
			error: null
		});
	});
});

describe('writeDraftData', () => {
	it('extracts draft metadata with defaults', () => {
		expect(
			writeDraftData({ title: 'Memo', version: 3, mode: 'edited', draft_id: 'd1' })
		).toMatchObject({ title: 'Memo', version: 3, mode: 'edited', draftId: 'd1' });
		expect(writeDraftData({})).toMatchObject({ title: 'Draft', version: 1, mode: 'updated' });
	});
});

describe('subAgentData', () => {
	it('strips the "Sub-agent result (model):" prefix and recovers the model', () => {
		const data = subAgentData(
			{ result: 'Sub-agent result (grok-4): Did the thing.' },
			{ objective: 'do it' }
		);
		expect(data.resultText).toBe('Did the thing.');
		expect(data.modelDisplay).toBe('grok-4');
		expect(data.objective).toBe('do it');
	});

	it('prefers explicit fields and passes plain results through', () => {
		const data = subAgentData(
			{ result: 'plain', objective: 'O', actual_model_name: 'claude' },
			null
		);
		expect(data).toEqual({ objective: 'O', modelDisplay: 'claude', resultText: 'plain' });
	});
});

describe('awaitResults', () => {
	it('maps each result with status and formatted duration', () => {
		const results = awaitResults({
			results: [
				{
					objective: 'A',
					status: 'complete',
					result_text: 'ok',
					duration_ms: 1500,
					model_key: 'm'
				},
				{ objective: 'B', status: 'error', error_message: 'boom', duration_ms: 200 }
			]
		});
		expect(results).toHaveLength(2);
		expect(results[0]).toMatchObject({
			status: 'complete',
			durationText: '1.5s',
			modelDisplay: 'm'
		});
		expect(results[1]).toMatchObject({
			status: 'error',
			errorMessage: 'boom',
			durationText: '200ms'
		});
	});

	it('returns [] when there are no results', () => {
		expect(awaitResults({})).toEqual([]);
	});
});

describe('codeExecutionData', () => {
	it('reads a map output (stdout/stderr/files) and code from inputs', () => {
		const data = codeExecutionData(
			{ success: true, stdout: 'hi', files: [{ filename: 'out.csv', file_id: 'f9' }] },
			{ code: 'print(1)' },
			'success'
		);
		expect(data).toMatchObject({ success: true, stdout: 'hi', code: 'print(1)' });
		expect(data.files).toEqual([{ filename: 'out.csv', fileId: 'f9', downloadUrl: null }]);
	});

	it('treats a string output as stdout', () => {
		expect(codeExecutionData('raw output', null, 'success')).toMatchObject({
			success: true,
			stdout: 'raw output',
			files: []
		});
	});

	it('falls back to error text for stderr and derives success from status', () => {
		expect(codeExecutionData({ error: 'bad' }, null, 'error')).toMatchObject({
			success: false,
			stderr: 'bad'
		});
	});
});
