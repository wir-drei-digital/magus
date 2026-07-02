<script lang="ts">
	import { Crown, Send, UserMinus, Wallet } from '@lucide/svelte';
	import {
		archiveOrganization,
		changeOrgMemberRole,
		inviteOrgMember,
		leaveOrg,
		removeOrgMember,
		resendOrgInvite,
		setMemberSpendCap,
		transferOrgOwnership,
		type OrgMemberEntry,
		type OrgMemberRole,
		type RpcResult
	} from '$lib/ash/api';
	import { formatCents } from '$lib/billing/format';
	import { Button, Section, confirmAction, CONTROL_CLASS } from '$lib/components/crud';
	import { getOrgAdmin } from '$lib/components/organizations/context';
	import {
		canConfirmArchive,
		isValidInviteEmail,
		memberDisplayName,
		sortMembers
	} from '$lib/organizations/members';

	const ctx = getOrgAdmin();

	// Hide removed rows; keep active members and pending invites, owners first.
	const visibleMembers = $derived(
		sortMembers(ctx.members.filter((member) => member.status !== 'removed'))
	);
	// The signed-in user's own membership row (drives the "you" marker + Leave).
	const myMembership = $derived(
		ctx.members.find((member) => member.userId === ctx.currentUserId) ?? null
	);

	function memberInitial(member: OrgMemberEntry): string {
		return memberDisplayName(member).slice(0, 1).toUpperCase();
	}

	// Reuse the shared CHF formatter so Members and the Usage tab render caps the
	// same way for a given `spend_cap_cents`; show "No cap" when unset.
	function formatCap(cents: number | null): string {
		if (cents === null) return 'No cap';
		return formatCents(cents);
	}

	// ── Invite (owner only) ──
	let email = $state('');
	let inviting = $state(false);
	let inviteError = $state<string | null>(null);
	let inviteOk = $state<string | null>(null);

	const canInvite = $derived(isValidInviteEmail(email) && !inviting);

	async function invite() {
		if (!canInvite || !ctx.org) return;
		const value = email.trim();
		inviting = true;
		inviteError = null;
		inviteOk = null;
		const result = await inviteOrgMember(ctx.org.id, value);
		inviting = false;
		if (result.success) {
			inviteOk = `Invitation sent to ${value}.`;
			email = '';
			await ctx.reload();
		} else {
			inviteError = result.errors[0]?.message ?? 'Could not send invitation.';
		}
	}

	// ── Per-row actions ──
	let busyId = $state<string | null>(null);
	let actionError = $state<string | null>(null);

	async function run(id: string, op: () => Promise<RpcResult<OrgMemberEntry>>) {
		busyId = id;
		actionError = null;
		const result = await op();
		busyId = null;
		if (!result.success) {
			actionError = result.errors[0]?.message ?? 'Action failed.';
			return;
		}
		capEditingId = null;
		await ctx.reload();
	}

	function changeRole(member: OrgMemberEntry, role: OrgMemberRole) {
		if (role === member.role) return;
		void run(member.id, () => changeOrgMemberRole(member.id, role));
	}

	async function transfer(member: OrgMemberEntry) {
		const ok = await confirmAction({
			title: 'Transfer ownership?',
			description: `${memberDisplayName(member)} becomes the owner; you become a regular member.`,
			confirmLabel: 'Transfer'
		});
		if (!ok) return;
		void run(member.id, () => transferOrgOwnership(member.id));
	}

	async function remove(member: OrgMemberEntry) {
		const ok = await confirmAction({
			title: 'Remove this member?',
			description: 'They lose access to the organization.',
			confirmLabel: 'Remove'
		});
		if (!ok) return;
		void run(member.id, () => removeOrgMember(member.id));
	}

	function resend(member: OrgMemberEntry) {
		void run(member.id, () => resendOrgInvite(member.id));
	}

	// ── Spend-cap inline editor ──
	let capEditingId = $state<string | null>(null);
	let capDraft = $state('');

	function startEditCap(member: OrgMemberEntry) {
		capEditingId = member.id;
		capDraft = member.spendCapCents === null ? '' : (member.spendCapCents / 100).toString();
	}

	function saveCap(member: OrgMemberEntry) {
		const trimmed = capDraft.trim();
		let cents: number | null = null;
		if (trimmed !== '') {
			const amount = Number(trimmed);
			if (!Number.isFinite(amount) || amount < 0) {
				actionError = 'Enter a spend cap in CHF (e.g. 50).';
				return;
			}
			cents = Math.round(amount * 100);
		}
		void run(member.id, () => setMemberSpendCap(member.id, cents));
	}

	// ── Delete organization (owner only) ──
	// A typed-name confirm gates the irreversible archive. On success we reload,
	// which now re-resolves membership: the ex-owner's org resolves to none and the
	// layout falls back to the Create-org card.
	let archiveConfirming = $state(false);
	let archiveTyped = $state('');
	let archiving = $state(false);
	let archiveError = $state<string | null>(null);

	const canArchive = $derived(
		!!ctx.org && canConfirmArchive(archiveTyped, ctx.org.name) && !archiving
	);

	function openArchive() {
		archiveConfirming = true;
		archiveTyped = '';
		archiveError = null;
	}

	function cancelArchive() {
		archiveConfirming = false;
		archiveTyped = '';
		archiveError = null;
	}

	async function archive() {
		if (!ctx.org || !canArchive) return;
		archiving = true;
		archiveError = null;
		const result = await archiveOrganization(ctx.org.id);
		archiving = false;
		if (result.success) {
			archiveConfirming = false;
			archiveTyped = '';
			await ctx.reload();
		} else {
			archiveError = result.errors[0]?.message ?? 'Could not delete the organization.';
		}
	}

	// ── Leave (member view) ──
	async function leave() {
		if (!myMembership) return;
		const ok = await confirmAction({
			title: 'Leave organization?',
			description: 'You lose access to this organization and its shared billing.',
			confirmLabel: 'Leave'
		});
		if (!ok) return;
		const result = await leaveOrg(myMembership.id);
		if (result.success) {
			await ctx.reload();
		} else {
			actionError = result.errors[0]?.message ?? 'Could not leave the organization.';
		}
	}
</script>

<div class="flex flex-col gap-5">
	{#if ctx.isOwner}
		<Section
			title="Invite member"
			description="They get an email invitation to join the organization."
			testid="org-invite"
		>
			<form
				class="flex items-start gap-2"
				onsubmit={(event) => {
					event.preventDefault();
					void invite();
				}}
			>
				<div class="flex flex-1 flex-col gap-1">
					<input
						type="email"
						bind:value={email}
						required
						placeholder="colleague@company.com"
						class={CONTROL_CLASS}
						data-testid="org-invite-email"
					/>
					{#if inviteError}
						<p class="text-xs text-destructive">{inviteError}</p>
					{:else if inviteOk}
						<p class="text-xs text-muted-foreground">{inviteOk}</p>
					{/if}
				</div>
				<Button type="submit" disabled={!canInvite} data-testid="org-invite-submit">
					{inviting ? 'Inviting…' : 'Invite'}
				</Button>
			</form>
		</Section>
	{/if}

	<Section title="Members" testid="org-members">
		{#if actionError}
			<p class="mb-2 text-xs text-destructive">{actionError}</p>
		{/if}
		<ul class="flex flex-col gap-1.5" data-testid="org-member-list">
			{#each visibleMembers as member (member.id)}
				{@const self = member.userId === ctx.currentUserId}
				<li
					class="flex flex-col gap-2 rounded-lg border p-3"
					data-testid="org-member"
					data-member-id={member.id}
				>
					<div class="flex items-center gap-3">
						<span
							class="flex size-9 shrink-0 items-center justify-center rounded-full bg-primary/10 text-sm font-semibold text-primary"
							aria-hidden="true"
						>
							{memberInitial(member)}
						</span>

						<div class="min-w-0 flex-1">
							<div class="flex items-center gap-2">
								<span class="truncate text-sm font-medium">{memberDisplayName(member)}</span>
								{#if self}<span class="text-xs text-muted-foreground">(you)</span>{/if}
								<span
									class="rounded px-1.5 py-0.5 text-[10px] font-medium {member.role === 'owner'
										? 'bg-primary/15 text-primary'
										: 'bg-secondary text-muted-foreground'}"
								>
									{member.role}
								</span>
							</div>
							{#if member.user?.email}
								<span class="truncate text-xs text-muted-foreground">{member.user.email}</span>
							{:else if member.inviteEmail}
								<span class="truncate text-xs text-muted-foreground">{member.inviteEmail}</span>
							{/if}
						</div>

						<span
							class="shrink-0 rounded px-1.5 py-0.5 text-[10px] font-medium {member.status ===
							'active'
								? 'bg-success/15 text-success'
								: 'bg-warning/15 text-warning'}"
							data-testid="org-member-status"
						>
							{member.status}
						</span>
						<span class="shrink-0 text-xs text-muted-foreground" data-testid="org-member-cap">
							{formatCap(member.spendCapCents)}
						</span>

						<div class="flex shrink-0 items-center gap-1">
							{#if busyId === member.id}
								<span
									class="size-4 animate-spin rounded-full border-2 border-current border-t-transparent text-muted-foreground"
								></span>
							{:else if ctx.isOwner && member.status === 'active' && !self}
								<select
									value={member.role}
									onchange={(event) =>
										changeRole(member, event.currentTarget.value as OrgMemberRole)}
									class="rounded-md border border-input bg-secondary px-1.5 py-1 text-xs outline-none focus:border-primary/60"
									title="Change role"
									data-testid="org-member-role"
								>
									<option value="member">Member</option>
									<option value="owner">Owner</option>
								</select>
								<button
									type="button"
									class="inline-flex size-7 items-center justify-center rounded-md text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
									title="Set spend cap"
									data-testid="org-member-cap-edit"
									onclick={() => startEditCap(member)}
								>
									<Wallet class="size-4" />
								</button>
								<button
									type="button"
									class="inline-flex size-7 items-center justify-center rounded-md text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
									title="Transfer ownership"
									data-testid="org-member-transfer"
									onclick={() => transfer(member)}
								>
									<Crown class="size-4" />
								</button>
								<button
									type="button"
									class="inline-flex size-7 items-center justify-center rounded-md text-destructive transition-colors hover:bg-destructive/10"
									title="Remove member"
									data-testid="org-member-remove"
									onclick={() => remove(member)}
								>
									<UserMinus class="size-4" />
								</button>
							{:else if ctx.isOwner && member.status === 'invited'}
								<button
									type="button"
									class="inline-flex size-7 items-center justify-center rounded-md text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
									title="Resend invite"
									data-testid="org-member-resend"
									onclick={() => resend(member)}
								>
									<Send class="size-4" />
								</button>
								<button
									type="button"
									class="inline-flex size-7 items-center justify-center rounded-md text-destructive transition-colors hover:bg-destructive/10"
									title="Revoke invite"
									data-testid="org-member-revoke"
									onclick={() => remove(member)}
								>
									<UserMinus class="size-4" />
								</button>
							{/if}
						</div>
					</div>

					{#if capEditingId === member.id}
						<form
							class="flex items-center gap-2 border-t pt-2"
							onsubmit={(event) => {
								event.preventDefault();
								saveCap(member);
							}}
						>
							<span class="text-xs text-muted-foreground">Monthly spend cap (CHF)</span>
							<input
								type="number"
								min="0"
								step="0.01"
								bind:value={capDraft}
								placeholder="No cap"
								class="{CONTROL_CLASS} max-w-32"
								data-testid="org-member-cap-input"
							/>
							<Button type="submit" size="sm" data-testid="org-member-cap-save">Save</Button>
							<Button
								type="button"
								size="sm"
								variant="ghost"
								onclick={() => (capEditingId = null)}
							>
								Cancel
							</Button>
						</form>
					{/if}
				</li>
			{/each}
		</ul>
	</Section>

	{#if !ctx.isOwner && myMembership}
		<Section
			title="Leave organization"
			description="You'll lose access to this organization's shared resources and billing."
			variant="danger"
			testid="org-leave"
		>
			<Button variant="destructive" onclick={() => void leave()} data-testid="org-leave-submit">
				Leave organization
			</Button>
		</Section>
	{/if}

	{#if ctx.isOwner && ctx.org}
		{@const org = ctx.org}
		<Section
			title="Danger zone"
			description="Deleting the organization removes all members, deactivates its workspaces, and cancels billing. This cannot be undone."
			variant="danger"
			testid="org-danger-zone"
		>
			{#if !archiveConfirming}
				<Button variant="destructive" onclick={openArchive} data-testid="org-archive-open">
					Delete organization
				</Button>
			{:else}
				<form
					class="flex flex-col gap-3"
					onsubmit={(event) => {
						event.preventDefault();
						void archive();
					}}
				>
					<label class="text-xs text-muted-foreground" for="org-archive-confirm-input">
						Type <span class="font-medium text-foreground">{org.name}</span> to confirm.
					</label>
					<input
						id="org-archive-confirm-input"
						type="text"
						bind:value={archiveTyped}
						autocomplete="off"
						autocapitalize="off"
						spellcheck="false"
						placeholder={org.name}
						class={CONTROL_CLASS}
						data-testid="org-archive-confirm-input"
					/>
					{#if archiveError}
						<p class="text-xs text-destructive" data-testid="org-archive-error">{archiveError}</p>
					{/if}
					<div class="flex items-center gap-2">
						<Button
							type="submit"
							variant="destructive"
							disabled={!canArchive}
							data-testid="org-archive-submit"
						>
							{archiving ? 'Deleting…' : 'Delete organization'}
						</Button>
						<Button type="button" variant="ghost" onclick={cancelArchive}>Cancel</Button>
					</div>
				</form>
			{/if}
		</Section>
	{/if}
</div>
