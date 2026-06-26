<script lang="ts">
	import { History, X } from '@lucide/svelte';
	import type { PageVersionDiff } from '$lib/ash/api';
	import { relativeTime } from '$lib/time';

	let {
		diff,
		restoring = false,
		onClose,
		onRestore
	}: {
		diff: PageVersionDiff;
		restoring?: boolean;
		onClose: () => void;
		onRestore: () => void;
	} = $props();

	const ACTION_LABELS: Record<string, string> = {
		update_body: 'Edited',
		create: 'Created',
		rename: 'Renamed',
		move_to_parent: 'Moved'
	};
</script>

<!-- Classic version_overlay: covers the editor, leaves the chrome visible. -->
<div class="absolute inset-0 z-20 flex flex-col bg-background" data-testid="brain-version-overlay">
	<div class="flex shrink-0 items-center justify-between gap-3 border-b bg-secondary/40 px-4 py-2">
		<div class="flex min-w-0 flex-col">
			<span class="truncate text-sm font-medium">
				Version from {relativeTime(diff.insertedAt)}
			</span>
			<span class="text-xs text-muted-foreground">
				{ACTION_LABELS[diff.actionName ?? ''] ?? diff.actionName ?? 'Edit'}
			</span>
		</div>
		<div class="flex items-center gap-1.5">
			{#if !diff.isLatest}
				<button
					type="button"
					class="wb-pill-btn shrink-0"
					data-testid="brain-restore-version"
					disabled={restoring}
					onclick={onRestore}
				>
					<History class="size-3.5" />
					<span>{restoring ? 'Restoring…' : 'Restore this version'}</span>
				</button>
			{/if}
			<button
				type="button"
				class="wb-pill-btn wb-pill-btn-square shrink-0"
				aria-label="Close version view"
				data-testid="brain-version-close"
				onclick={onClose}
			>
				<X class="size-3.5" />
			</button>
		</div>
	</div>

	<div class="wb-scroll min-h-0 flex-1 overflow-y-auto bg-card px-6 py-4">
		{#if diff.rows.length === 0}
			<p class="text-sm text-muted-foreground">No body changes in this version.</p>
		{:else}
			<div class="font-mono text-xs leading-relaxed" data-testid="brain-version-diff">
				{#each diff.rows as row, index (index)}
					{#if row.kind === 'gap'}
						<div class="my-1 select-none text-center text-muted-foreground/60">
							⋯ {row.count} unchanged {row.count === 1 ? 'line' : 'lines'}
						</div>
					{:else}
						<div
							class="whitespace-pre-wrap px-2 py-0.5 {row.kind === 'del'
								? 'bg-destructive/10'
								: row.kind === 'ins'
									? 'bg-success/10'
									: ''}"
						>
							<span class="mr-2 select-none text-muted-foreground/60">
								{row.kind === 'del' ? '−' : row.kind === 'ins' ? '+' : ' '}
							</span>{#each row.tokens as token, tokenIndex (tokenIndex)}<span
									class={token.kind === 'removed'
										? 'rounded bg-destructive/30'
										: token.kind === 'added'
											? 'rounded bg-success/30'
											: ''}>{token.text}</span
								>{/each}
						</div>
					{/if}
				{/each}
			</div>
		{/if}
	</div>
</div>
