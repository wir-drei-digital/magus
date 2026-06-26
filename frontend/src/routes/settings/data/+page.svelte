<script lang="ts">
	import { onMount } from 'svelte';
	import { Download, TriangleAlert } from '@lucide/svelte';
	import * as Dialog from '$lib/components/ui/dialog';
	import { Button } from '$lib/components/ui/button';
	import { Section as SettingsSection, CONTROL_CLASS } from '$lib/components/crud';
	import {
		accountDeletionPreflight,
		deleteAccount,
		type AccountDeletionPreflight
	} from '$lib/ash/api';
	import { session } from '$lib/stores/session.svelte';

	const FIELD =
		CONTROL_CLASS;

	let preflight = $state<AccountDeletionPreflight | null>(null);
	let loading = $state(true);

	let dialogOpen = $state(false);
	let confirmEmail = $state('');
	let deleting = $state(false);
	let deleteError = $state<string | null>(null);

	const email = $derived(session.user?.email ?? '');
	const emailMatches = $derived(
		confirmEmail.trim().toLowerCase() === email.toLowerCase() && email !== ''
	);

	// Each line of "what gets deleted", skipping zero counts.
	const summaryLines = $derived.by(() => {
		if (!preflight?.canDelete) return [];
		const s = preflight.summary;
		return [
			[s.conversationCount, 'conversation'],
			[s.brainCount, 'brain'],
			[s.memoryCount, 'memory', 'memories'],
			[s.promptCount, 'prompt'],
			[s.draftCount, 'draft'],
			[s.customAgentCount, 'custom agent']
		]
			.filter(([count]) => (count as number) > 0)
			.map(([count, singular, plural]) => {
				const n = count as number;
				const word = n === 1 ? (singular as string) : ((plural as string) ?? `${singular}s`);
				return `${n} ${word}`;
			});
	});

	onMount(() => {
		void accountDeletionPreflight().then((result) => {
			if (result.success) preflight = result.data;
			loading = false;
		});
	});

	async function confirmDelete() {
		if (deleting || !emailMatches) return;
		deleting = true;
		deleteError = null;
		const result = await deleteAccount(confirmEmail.trim());
		if (result.success) {
			// The server cleared the session; leave the SPA entirely.
			window.location.href = '/sign-in';
			return;
		}
		deleting = false;
		deleteError = result.errors[0]?.message ?? 'Could not delete account';
	}
</script>

<div class="space-y-6" data-testid="settings-data">
	<SettingsSection
		title="Export your data"
		description="Everything you own, as a single JSON file."
	>
		<p class="mb-3 text-xs text-muted-foreground">
			Conversations, brains, memories, custom agents, prompts, and drafts.
		</p>
		<!-- Browser download from the Phoenix controller (session-authenticated);
		     not an SPA route, so a plain link triggers the file download. -->
		<a href="/settings/data/export" data-testid="data-export">
			<Button variant="outline">
				<Download class="size-4" />
				Download export
			</Button>
		</a>
	</SettingsSection>

	<SettingsSection title="Delete account" description="Permanent. This cannot be undone.">
		{#if loading}
			<div class="h-10 animate-pulse rounded-md bg-muted/60"></div>
		{:else if preflight && !preflight.canDelete}
			<div
				class="flex items-start gap-2 rounded-lg border border-warning/40 bg-warning/10 p-3 text-xs"
				data-testid="data-delete-blocked"
			>
				<TriangleAlert class="size-4 shrink-0 text-warning" />
				<p>
					You're the only admin of {preflight.soleAdminWorkspaces.join(', ')}. Transfer admin rights
					or delete those workspaces before deleting your account.
				</p>
			</div>
		{:else}
			<p class="mb-3 text-xs text-muted-foreground">
				Aggregated usage statistics are anonymized and retained for billing.
			</p>
			<Button
				variant="destructive"
				onclick={() => (dialogOpen = true)}
				data-testid="data-delete-open"
			>
				<TriangleAlert class="size-4" />
				Delete account
			</Button>
		{/if}
	</SettingsSection>
</div>

<Dialog.Root bind:open={dialogOpen}>
	<Dialog.Content class="sm:max-w-md" data-testid="data-delete-dialog">
		<Dialog.Header>
			<Dialog.Title>Delete your account?</Dialog.Title>
			<Dialog.Description>
				This permanently deletes your account and everything you own.
			</Dialog.Description>
		</Dialog.Header>

		{#if summaryLines.length > 0}
			<ul class="list-disc space-y-0.5 pl-5 text-xs text-muted-foreground">
				{#each summaryLines as line (line)}
					<li>{line}</li>
				{/each}
			</ul>
		{/if}

		<form
			class="space-y-3"
			onsubmit={(event) => {
				event.preventDefault();
				void confirmDelete();
			}}
		>
			<label class="flex flex-col gap-1.5">
				<span class="text-xs font-medium text-muted-foreground">
					Type <span class="font-mono">{email}</span> to confirm
				</span>
				<input
					type="email"
					bind:value={confirmEmail}
					autocomplete="off"
					data-testid="data-delete-confirm-email"
					class={FIELD}
				/>
			</label>
			{#if deleteError}
				<p class="text-xs text-destructive">{deleteError}</p>
			{/if}
			<Dialog.Footer>
				<Button type="button" variant="ghost" onclick={() => (dialogOpen = false)}>Cancel</Button>
				<Button
					type="submit"
					variant="destructive"
					disabled={!emailMatches || deleting}
					data-testid="data-delete-confirm"
				>
					{deleting ? 'Deleting…' : 'Delete account'}
				</Button>
			</Dialog.Footer>
		</form>
	</Dialog.Content>
</Dialog.Root>
