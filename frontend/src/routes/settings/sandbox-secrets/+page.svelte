<script lang="ts">
	import { onMount } from 'svelte';
	import { KeyRound, Plus, Trash2 } from '@lucide/svelte';
	import { Section as SettingsSection, Button, CONTROL_CLASS } from '$lib/components/crud';
	import {
		mySandboxSecrets,
		createSandboxSecret,
		destroySandboxSecret,
		type SandboxSecretEntry
	} from '$lib/ash/api';
	import { relativeTime } from '$lib/time';

	const FIELD = CONTROL_CLASS;

	let secrets = $state<SandboxSecretEntry[]>([]);
	let loading = $state(true);

	// Add-form state. `newValue` is the write-only plaintext; it never comes back
	// from the server and is cleared as soon as the secret is stored.
	let newKey = $state('');
	let newValue = $state('');
	let newDescription = $state('');
	let creating = $state(false);
	let createError = $state<string | null>(null);

	// Two-click delete confirm (mirrors the API-tokens page): the first click arms
	// the row, a second within the window confirms.
	let confirmingDeleteId = $state<string | null>(null);

	onMount(() => {
		void load();
	});

	async function load() {
		const result = await mySandboxSecrets();
		if (result.success) secrets = result.data;
		loading = false;
	}

	async function add() {
		if (creating || newKey.trim() === '' || newValue === '') return;
		creating = true;
		createError = null;
		const result = await createSandboxSecret({
			key: newKey.trim(),
			value: newValue,
			...(newDescription.trim() ? { description: newDescription.trim() } : {})
		});
		creating = false;
		if (result.success) {
			secrets = [result.data, ...secrets.filter((entry) => entry.id !== result.data.id)];
			// Clear the inputs; the value must not linger in the DOM after submit.
			newKey = '';
			newValue = '';
			newDescription = '';
		} else {
			createError = result.errors[0]?.message ?? 'Could not save secret';
		}
	}

	async function remove(secret: SandboxSecretEntry) {
		if (confirmingDeleteId !== secret.id) {
			confirmingDeleteId = secret.id;
			setTimeout(() => {
				if (confirmingDeleteId === secret.id) confirmingDeleteId = null;
			}, 3000);
			return;
		}
		confirmingDeleteId = null;
		const result = await destroySandboxSecret(secret.id);
		if (result.success) {
			secrets = secrets.filter((entry) => entry.id !== secret.id);
		}
	}
</script>

{#if loading}
	<div
		class="h-48 animate-pulse rounded-xl bg-muted/60"
		data-testid="settings-sandbox-secrets-loading"
	></div>
{:else}
	<div class="space-y-6" data-testid="sandbox-secrets-page">
		<SettingsSection
			title="Sandbox secrets"
			description="Stored once per account and injected into a skill's sandbox only when the skill declares the key. Values are write-only: they are never shown again after you save them."
		>
			<form
				class="mb-4 space-y-3"
				onsubmit={(event) => {
					event.preventDefault();
					void add();
				}}
			>
				<div class="grid gap-2 sm:grid-cols-2">
					<label class="flex flex-col gap-1.5">
						<span class="text-xs font-medium text-muted-foreground">Key</span>
						<input
							type="text"
							bind:value={newKey}
							maxlength="200"
							placeholder="DEEPL_API_KEY"
							autocomplete="off"
							spellcheck="false"
							data-testid="secret-key"
							class="{FIELD} font-mono"
						/>
					</label>
					<label class="flex flex-col gap-1.5">
						<span class="text-xs font-medium text-muted-foreground">Value</span>
						<input
							type="password"
							bind:value={newValue}
							placeholder="Paste the secret value"
							autocomplete="off"
							data-testid="secret-value"
							class={FIELD}
						/>
					</label>
				</div>
				<label class="flex flex-col gap-1.5">
					<span class="text-xs font-medium text-muted-foreground">Description (optional)</span>
					<input
						type="text"
						bind:value={newDescription}
						maxlength="500"
						placeholder="What this secret is for"
						data-testid="secret-description"
						class={FIELD}
					/>
				</label>
				{#if createError}
					<p class="text-xs text-destructive">{createError}</p>
				{/if}
				<Button
					type="submit"
					disabled={creating || newKey.trim() === '' || newValue === ''}
					data-testid="secret-add"
				>
					<Plus class="size-4" />
					{creating ? 'Saving…' : 'Add secret'}
				</Button>
			</form>

			{#if secrets.length === 0}
				<p class="py-4 text-center text-sm text-muted-foreground">No secrets yet.</p>
			{:else}
				<ul class="divide-y" data-testid="secret-list">
					{#each secrets as secret (secret.id)}
						<li class="flex items-center gap-3 py-3 first:pt-0 last:pb-0">
							<KeyRound class="size-4 shrink-0 text-muted-foreground" />
							<div class="min-w-0 flex-1">
								<p class="truncate font-mono text-sm font-medium">{secret.key}</p>
								<p class="truncate text-xs text-muted-foreground">
									{#if secret.description}{secret.description} ·
									{/if}added
									{relativeTime(secret.insertedAt)}
								</p>
							</div>
							<button
								type="button"
								class="wb-pill-btn wb-pill-btn-square shrink-0 {confirmingDeleteId === secret.id
									? '!border-destructive !bg-destructive !text-destructive-foreground'
									: 'hover:!text-destructive'}"
								title={confirmingDeleteId === secret.id ? 'Confirm delete' : 'Delete'}
								data-testid="secret-delete"
								onclick={() => void remove(secret)}
							>
								<Trash2 class="size-3.5" />
							</button>
						</li>
					{/each}
				</ul>
			{/if}
		</SettingsSection>
	</div>
{/if}
