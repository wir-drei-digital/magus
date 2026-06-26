/**
 * Pure data extraction for the specialized tool renderers (runes-free, tested).
 *
 * Mirrors the workbench tool_call_component.ex: each known tool name maps to a
 * specialized layout, and the layout's fields are pulled from the tool's
 * `output` map (the persisted, sanitized result) and `inputs`. Operates on the
 * snake_case shapes the agent persists / broadcasts.
 */
import type { ToolStatus } from './events';

export type SpecializedToolType =
	| 'sandbox'
	| 'service'
	| 'file_download'
	| 'write_draft'
	| 'sub_agent'
	| 'await_sub_agents';

const SANDBOX_TOOLS = [
	'run_code',
	'runcode',
	'run_python',
	'execute_code',
	'exec_command',
	'install_packages'
];

/** Which specialized renderer a tool name uses, or null for the generic card. */
export function specializedToolType(toolName: string): SpecializedToolType | null {
	const name = toolName.toLowerCase();
	if (SANDBOX_TOOLS.includes(name)) return 'sandbox';
	if (name === 'start_service') return 'service';
	if (name === 'sandbox_download_file') return 'file_download';
	if (name === 'write_draft') return 'write_draft';
	if (name === 'spawn_sub_agent') return 'sub_agent';
	if (name === 'await_sub_agents') return 'await_sub_agents';
	return null;
}

const obj = (value: unknown): Record<string, unknown> =>
	value && typeof value === 'object' && !Array.isArray(value)
		? (value as Record<string, unknown>)
		: {};
const str = (value: unknown): string => (typeof value === 'string' ? value : '');
const strOrNull = (value: unknown): string | null => (typeof value === 'string' ? value : null);
const num = (value: unknown): number | null => (typeof value === 'number' ? value : null);

export function formatBytes(bytes: number | null): string | null {
	if (bytes === null) return null;
	if (bytes < 1024) return `${bytes} B`;
	if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
	return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

export function formatDuration(ms: number | null): string | null {
	if (ms === null) return null;
	return ms < 1000 ? `${ms}ms` : `${(ms / 1000).toFixed(1)}s`;
}

export type ServiceData = { previewUrl: string | null; name: string; status: string };

export function serviceData(output: unknown): ServiceData {
	const o = obj(output);
	return {
		previewUrl: strOrNull(o.preview_url),
		name: str(o.service_name) || 'service',
		status: str(o.status) || 'running'
	};
}

export type FileDownloadData = {
	fileId: string | null;
	filename: string;
	downloadUrl: string | null;
	mimeType: string | null;
	sizeText: string | null;
	error: string | null;
};

export function fileDownloadData(output: unknown): FileDownloadData {
	const o = obj(output);
	return {
		fileId: strOrNull(o.file_id),
		filename: str(o.filename) || 'file',
		downloadUrl: strOrNull(o.download_url),
		mimeType: strOrNull(o.mime_type),
		sizeText: formatBytes(num(o.size_bytes)),
		error: strOrNull(o.error)
	};
}

export type WriteDraftData = {
	title: string;
	version: number;
	mode: string;
	lineCount: number | null;
	editedRange: string | null;
	draftId: string | null;
};

export function writeDraftData(output: unknown): WriteDraftData {
	const o = obj(output);
	return {
		title: str(o.title) || 'Draft',
		version: num(o.version) ?? 1,
		mode: str(o.mode) || 'updated',
		lineCount: num(o.line_count),
		editedRange: strOrNull(o.edited_range),
		draftId: strOrNull(o.draft_id)
	};
}

export type SubAgentData = {
	objective: string | null;
	modelDisplay: string | null;
	resultText: string | null;
};

const SUB_AGENT_PREFIX = /^Sub-agent (?:result|failed) \(([^)]*)\):\s*/;

export function subAgentData(
	output: unknown,
	inputs: Record<string, unknown> | null
): SubAgentData {
	const o = obj(output);
	const i = inputs ?? {};
	const raw = strOrNull(o.result);

	// Strip the "Sub-agent result (model): " prefix the runner adds, recovering
	// the model name from it when no explicit field is present.
	let resultText = raw;
	let prefixModel: string | null = null;
	if (raw) {
		const match = raw.match(SUB_AGENT_PREFIX);
		if (match) {
			prefixModel = match[1] || null;
			resultText = raw.replace(SUB_AGENT_PREFIX, '');
		}
	}

	return {
		objective: strOrNull(o.objective) ?? strOrNull(i.objective),
		modelDisplay:
			strOrNull(o.actual_model_name) ?? strOrNull(o.model_key) ?? prefixModel ?? strOrNull(o.model),
		resultText
	};
}

export type AwaitResult = {
	objective: string | null;
	status: string;
	resultText: string | null;
	errorMessage: string | null;
	modelDisplay: string | null;
	durationText: string | null;
};

export function awaitResults(output: unknown): AwaitResult[] {
	const o = obj(output);
	const results = Array.isArray(o.results) ? o.results : [];
	return results.map((entry) => {
		const r = obj(entry);
		return {
			objective: strOrNull(r.objective),
			status: str(r.status) || 'unknown',
			resultText: strOrNull(r.result_text),
			errorMessage: strOrNull(r.error_message),
			modelDisplay: strOrNull(r.model_key),
			durationText: formatDuration(num(r.duration_ms))
		};
	});
}

export type CodeExecFile = { filename: string; fileId: string | null; downloadUrl: string | null };
export type CodeExecData = {
	success: boolean;
	stdout: string;
	stderr: string;
	code: string;
	files: CodeExecFile[];
};

export function codeExecutionData(
	output: unknown,
	inputs: Record<string, unknown> | null,
	status: ToolStatus
): CodeExecData {
	const i = inputs ?? {};
	const codeFromInputs = str(i.code) || str(i.command) || str(i.script) || '';

	if (typeof output === 'string') {
		return {
			success: status === 'success',
			stdout: output,
			stderr: '',
			code: codeFromInputs,
			files: []
		};
	}

	const o = obj(output);
	const rawFiles = Array.isArray(o.files)
		? o.files
		: Array.isArray(o.files_created)
			? o.files_created
			: [];
	return {
		success: o.success === true || (o.success === undefined && status === 'success'),
		stdout: str(o.stdout),
		stderr: str(o.stderr) || str(o.error),
		code: str(o.code) || codeFromInputs,
		files: rawFiles.map((entry) => {
			const f = obj(entry);
			return {
				filename: str(f.filename) || 'file',
				fileId: strOrNull(f.file_id),
				downloadUrl: strOrNull(f.download_url)
			};
		})
	};
}
