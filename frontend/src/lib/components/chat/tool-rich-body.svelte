<script lang="ts">
	import { Ban, Check, CircleCheck, Clock, Download, ScrollText, X } from '@lucide/svelte';
	import type { ToolView } from '$lib/chat/events';
	import {
		awaitResults,
		codeExecutionData,
		subAgentData,
		type SpecializedToolType
	} from '$lib/chat/tool-render';
	import Markdown from './markdown.svelte';

	let { view, type }: { view: ToolView; type: SpecializedToolType } = $props();

	const sub = $derived(type === 'sub_agent' ? subAgentData(view.output, view.inputs) : null);
	const results = $derived(type === 'await_sub_agents' ? awaitResults(view.output) : []);
	const code = $derived(
		type === 'sandbox' ? codeExecutionData(view.output, view.inputs, view.status) : null
	);
</script>

{#if type === 'sub_agent' && sub}
	{#if sub.objective}
		<details class="group/prompt">
			<summary
				class="flex cursor-pointer list-none items-center gap-1.5 text-muted-foreground select-none"
			>
				<ScrollText class="size-3 shrink-0" />
				View prompt
			</summary>
			<div class="mt-1 whitespace-pre-wrap text-muted-foreground">{sub.objective}</div>
		</details>
	{/if}
	{#if sub.resultText}
		<div class="prose prose-sm dark:prose-invert max-w-none text-xs">
			<Markdown text={sub.resultText} />
		</div>
	{/if}
{:else if type === 'await_sub_agents'}
	{#if results.length === 0}
		<p class="text-muted-foreground">No sub-agents returned.</p>
	{/if}
	{#each results as result, index (index)}
		<details class="group/result">
			<summary
				class="flex cursor-pointer list-none items-center gap-1.5 text-muted-foreground select-none"
			>
				{#if result.status === 'complete'}
					<Check class="size-3 shrink-0 text-success" />
				{:else if result.status === 'error'}
					<X class="size-3 shrink-0 text-destructive" />
				{:else if result.status === 'timed_out'}
					<Clock class="size-3 shrink-0 text-warning" />
				{:else if result.status === 'cancelled'}
					<Ban class="size-3 shrink-0 text-muted-foreground/60" />
				{:else}
					<Clock class="size-3 shrink-0 text-muted-foreground/60" />
				{/if}
				<span class="min-w-0 truncate">{result.objective ?? 'Sub-agent'}</span>
				{#if result.modelDisplay}
					<span class="shrink-0 font-mono text-[10px] text-muted-foreground/50">
						{result.modelDisplay}
					</span>
				{/if}
				{#if result.durationText}
					<span class="shrink-0 text-[10px] text-muted-foreground/50">{result.durationText}</span>
				{/if}
			</summary>
			<div class="mt-1 ml-[18px] space-y-1">
				{#if result.resultText}
					<div class="prose prose-sm dark:prose-invert max-w-none text-xs">
						<Markdown text={result.resultText} />
					</div>
				{/if}
				{#if result.errorMessage}
					<p class="text-destructive/80">{result.errorMessage}</p>
				{/if}
			</div>
		</details>
	{/each}
{:else if type === 'sandbox' && code}
	{#if code.code}
		<div>
			<p class="mb-0.5 font-medium text-muted-foreground">Code</p>
			<pre
				class="overflow-x-auto rounded bg-secondary/60 px-2 py-1 font-mono text-[11px] whitespace-pre-wrap">{code.code}</pre>
		</div>
	{/if}
	{#if code.stdout}
		<div>
			<p class="mb-0.5 font-medium text-muted-foreground">Output</p>
			<pre
				class="overflow-x-auto rounded bg-secondary/60 px-2 py-1 font-mono text-[11px] whitespace-pre-wrap">{code.stdout}</pre>
		</div>
	{/if}
	{#if code.stderr}
		<div>
			<p class="mb-0.5 font-medium {code.success ? 'text-warning' : 'text-destructive'}">
				{code.success ? 'Warnings' : 'Error'}
			</p>
			<pre
				class="overflow-x-auto rounded bg-destructive/10 px-2 py-1 font-mono text-[11px] whitespace-pre-wrap">{code.stderr}</pre>
		</div>
	{/if}
	{#if code.files.length > 0}
		<div>
			<p class="mb-0.5 font-medium text-muted-foreground">Files</p>
			<div class="space-y-0.5">
				{#each code.files as file (file.filename)}
					{#if file.downloadUrl}
						<a
							href={file.downloadUrl}
							target="_blank"
							rel="noopener noreferrer"
							class="flex items-center gap-1.5 text-primary hover:underline"
						>
							<Download class="size-3 shrink-0" />
							{file.filename}
						</a>
					{:else}
						<span class="flex items-center gap-1.5 text-muted-foreground">
							<CircleCheck class="size-3 shrink-0 text-success" />
							{file.filename}
						</span>
					{/if}
				{/each}
			</div>
		</div>
	{/if}
{/if}
