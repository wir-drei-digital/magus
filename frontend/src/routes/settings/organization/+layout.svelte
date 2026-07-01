<script lang="ts">
	import type { Snippet } from 'svelte';
	import { base } from '$app/paths';
	import { page } from '$app/state';
	import { BarChart3, CreditCard, Users } from '@lucide/svelte';
	import { createOrganization, listOrgMembers, myOrganization } from '$lib/ash/api';
	import { session } from '$lib/stores/session.svelte';
	import { Button, Field, Section, CONTROL_CLASS } from '$lib/components/crud';
	import { setOrgAdmin, type OrgAdminState } from '$lib/components/organizations/context';

	let { children }: { children: Snippet } = $props();

	// Named `admin` (not `state`) so the many `$state(...)` rune calls below aren't
	// misparsed as `$`-store access of a local `state` variable.
	const admin = $state<OrgAdminState>({
		org: null,
		members: [],
		loading: true,
		error: null,
		isOwner: false,
		currentUserId: null,
		reload
	});
	setOrgAdmin(admin);

	// Resolve the signed-in user's membership (0 or 1 rows), loading the org.
	async function loadOrg() {
		const result = await myOrganization();
		if (!result.success) {
			admin.org = null;
			admin.isOwner = false;
			admin.error = result.errors[0]?.message ?? 'Could not load your organization.';
			return;
		}
		const membership = result.data[0] ?? null;
		admin.org = membership?.organization ?? null;
		admin.isOwner = membership?.role === 'owner';
		admin.error = null;
	}

	async function reload() {
		if (!admin.org) {
			admin.members = [];
			return;
		}
		const result = await listOrgMembers(admin.org.id);
		if (result.success) {
			admin.members = result.data;
			admin.error = null;
		} else {
			admin.error = result.errors[0]?.message ?? 'Could not load members.';
		}
	}

	// (Re)load once the signed-in user is known — the owner gate and the "you"
	// marker both need their id. Only uid is a tracked dependency; the async body
	// isn't reactive past the first await.
	$effect(() => {
		const uid = session.user?.id;
		if (!uid) return;
		admin.currentUserId = uid;
		admin.loading = true;
		void (async () => {
			await loadOrg();
			await reload();
			admin.loading = false;
		})();
	});

	// ── Create-organization form (shown when the user isn't in an org yet) ──
	let name = $state('');
	let slug = $state('');
	let slugEdited = $state(false);
	let creating = $state(false);
	let createError = $state<string | null>(null);

	function slugify(value: string): string {
		return value
			.toLowerCase()
			.replace(/[^a-z0-9\s-]/g, '')
			.replace(/\s+/g, '-')
			.replace(/^-+|-+$/g, '');
	}

	function onNameInput() {
		if (!slugEdited) slug = slugify(name);
	}

	const canCreate = $derived(name.trim() !== '' && slug.trim().length >= 2 && !creating);

	async function createOrg() {
		if (!canCreate) return;
		creating = true;
		createError = null;
		const result = await createOrganization(name.trim(), slug.trim());
		creating = false;
		if (!result.success) {
			createError = result.errors[0]?.message ?? 'Organization could not be created.';
			return;
		}
		name = '';
		slug = '';
		slugEdited = false;
		admin.loading = true;
		await loadOrg();
		await reload();
		admin.loading = false;
	}

	const tabs = $derived([
		{ id: 'members', label: 'Members', icon: Users, href: `${base}/settings/organization/members` },
		{ id: 'usage', label: 'Usage', icon: BarChart3, href: `${base}/settings/organization/usage` },
		{
			id: 'billing',
			label: 'Billing',
			icon: CreditCard,
			href: `${base}/settings/organization/billing`
		}
	]);

	const activeTab = $derived.by(() => {
		const path = page.url.pathname;
		if (path.endsWith('/usage')) return 'usage';
		if (path.endsWith('/billing')) return 'billing';
		return 'members';
	});
</script>

{#if admin.loading}
	<div class="flex min-h-40 items-center justify-center" data-testid="org-loading">
		<span
			class="size-5 animate-spin rounded-full border-2 border-current border-t-transparent text-muted-foreground"
		></span>
	</div>
{:else if !admin.org}
	<Section
		title="Create an organization"
		description="Organizations centralize billing and let you manage members and per-member spend."
		testid="org-create"
	>
		<form
			class="flex flex-col gap-3"
			onsubmit={(event) => {
				event.preventDefault();
				void createOrg();
			}}
		>
			<Field label="Organization name" required>
				<input
					type="text"
					bind:value={name}
					oninput={onNameInput}
					placeholder="e.g. Acme Inc"
					class={CONTROL_CLASS}
					data-testid="org-create-name"
				/>
			</Field>

			<Field
				label="URL slug"
				required
				hint="Lowercase letters, numbers, and hyphens. Used in URLs."
			>
				<input
					type="text"
					bind:value={slug}
					oninput={() => (slugEdited = true)}
					placeholder="acme"
					class={CONTROL_CLASS}
					data-testid="org-create-slug"
				/>
			</Field>

			{#if createError}
				<p class="text-xs text-destructive" data-testid="org-create-error">{createError}</p>
			{/if}

			<div class="flex justify-end">
				<Button type="submit" disabled={!canCreate} data-testid="org-create-submit">
					{creating ? 'Creating…' : 'Create organization'}
				</Button>
			</div>
		</form>
	</Section>
{:else}
	<div class="flex flex-col gap-5" data-testid="org-admin-view">
		<div>
			<h2 class="text-base font-semibold">{admin.org.name}</h2>
			<p class="text-xs text-muted-foreground">{admin.org.slug}</p>
		</div>

		<nav class="border-b" data-testid="org-nav">
			<ul class="flex flex-row gap-1 overflow-x-auto">
				{#each tabs as tab (tab.id)}
					<li>
						<a
							href={tab.href}
							data-testid="org-nav-{tab.id}"
							aria-current={activeTab === tab.id ? 'page' : undefined}
							class="flex items-center gap-2 border-b-2 px-3 py-2 text-sm transition-colors {activeTab ===
							tab.id
								? 'border-primary font-medium text-foreground'
								: 'border-transparent text-muted-foreground hover:text-foreground'}"
						>
							<tab.icon class="size-4 shrink-0" />
							<span>{tab.label}</span>
						</a>
					</li>
				{/each}
			</ul>
		</nav>

		{@render children()}
	</div>
{/if}
