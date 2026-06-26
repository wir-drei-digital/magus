<script lang="ts">
	import { Crown, Send, UserMinus, X } from '@lucide/svelte';
	import {
		changeWorkspaceMemberRole,
		deactivateWorkspaceMember,
		inviteWorkspaceMember,
		resendWorkspaceInvite,
		transferWorkspaceOwnership,
		type RpcResult,
		type WorkspaceMemberEntry,
		type WorkspaceMemberRole
	} from '$lib/ash/api';
	import { Button } from '$lib/components/ui/button';
	import SettingsSection from '$lib/components/crud/section.svelte';
	import { getWorkspaceAdmin } from '$lib/components/workspaces/context';
	import { confirmAction } from '$lib/stores/confirm.svelte';

	const ctx = getWorkspaceAdmin();

	const inputClass =
		'w-full rounded-md border border-input bg-secondary px-2.5 py-1.5 text-sm outline-none focus:border-primary/60';

	// Hide soft-removed rows; show active + pending invites (classic parity).
	const visibleMembers = $derived(ctx.members.filter((member) => member.status !== 'deactivated'));

	let email = $state('');
	let inviting = $state(false);
	let inviteError = $state<string | null>(null);
	let inviteOk = $state<string | null>(null);

	let busyId = $state<string | null>(null);
	let actionError = $state<string | null>(null);

	function memberName(member: WorkspaceMemberEntry): string {
		return member.user?.displayName || member.user?.email || member.inviteEmail || 'Unknown';
	}

	function memberInitial(member: WorkspaceMemberEntry): string {
		return memberName(member).slice(0, 1).toUpperCase();
	}

	async function invite() {
		const value = email.trim();
		if (!value || inviting || !ctx.workspace) return;
		inviting = true;
		inviteError = null;
		inviteOk = null;
		const result = await inviteWorkspaceMember(ctx.workspace.id, value);
		inviting = false;
		if (result.success) {
			inviteOk = `Invitation sent to ${value}.`;
			email = '';
			await ctx.reloadMembers();
		} else {
			inviteError = result.errors[0]?.message ?? 'Could not send invitation';
		}
	}

	async function run(id: string, op: () => Promise<RpcResult<WorkspaceMemberEntry>>) {
		busyId = id;
		actionError = null;
		const result = await op();
		busyId = null;
		if (!result.success) {
			actionError = result.errors[0]?.message ?? 'Action failed';
			return;
		}
		await ctx.reloadMembers();
	}

	function changeRole(member: WorkspaceMemberEntry, role: WorkspaceMemberRole) {
		if (role === member.role) return;
		void run(member.id, () => changeWorkspaceMemberRole(member.id, role));
	}

	async function transfer(member: WorkspaceMemberEntry) {
		const ok = await confirmAction({
			title: 'Transfer ownership?',
			description: 'This member becomes the owner; you become a regular member.',
			confirmLabel: 'Transfer'
		});
		if (!ok) return;
		void run(member.id, () => transferWorkspaceOwnership(member.id));
	}

	async function remove(member: WorkspaceMemberEntry) {
		const ok = await confirmAction({
			title: 'Remove this member?',
			description: 'They lose access to the workspace.',
			confirmLabel: 'Remove'
		});
		if (!ok) return;
		void run(member.id, () => deactivateWorkspaceMember(member.id));
	}

	function resend(member: WorkspaceMemberEntry) {
		void run(member.id, () => resendWorkspaceInvite(member.id));
	}

	async function revoke(member: WorkspaceMemberEntry) {
		const ok = await confirmAction({ title: 'Revoke this invitation?', confirmLabel: 'Revoke' });
		if (!ok) return;
		void run(member.id, () => deactivateWorkspaceMember(member.id));
	}
</script>

<div class="flex flex-col gap-5">
	<SettingsSection
		title="Invite member"
		description="They get an email invitation to join."
		testid="workspace-invite"
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
					class={inputClass}
					data-testid="workspace-invite-email"
				/>
				{#if inviteError}
					<p class="text-xs text-destructive">{inviteError}</p>
				{:else if inviteOk}
					<p class="text-xs text-muted-foreground">{inviteOk}</p>
				{/if}
			</div>
			<Button
				type="submit"
				disabled={email.trim() === '' || inviting}
				data-testid="workspace-invite-submit"
			>
				{inviting ? 'Inviting…' : 'Invite'}
			</Button>
		</form>
	</SettingsSection>

	<SettingsSection title="Members" testid="workspace-members">
		{#if actionError}
			<p class="mb-2 text-xs text-destructive">{actionError}</p>
		{/if}
		<ul class="flex flex-col gap-1.5" data-testid="workspace-member-list">
			{#each visibleMembers as member (member.id)}
				{@const self = member.id === ctx.currentMemberId}
				<li
					class="flex items-center gap-3 rounded-lg border p-3"
					data-testid="workspace-member"
					data-member-id={member.id}
				>
					<span
						class="flex size-9 shrink-0 items-center justify-center rounded-full bg-primary/10 text-sm font-semibold text-primary"
						aria-hidden="true"
					>
						{memberInitial(member)}
					</span>

					<div class="min-w-0 flex-1">
						<div class="flex items-center gap-2">
							<span class="truncate text-sm font-medium">{memberName(member)}</span>
							{#if self}<span class="text-xs text-muted-foreground">(you)</span>{/if}
							<span
								class="rounded px-1.5 py-0.5 text-[10px] font-medium {member.role === 'admin'
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
					>
						{member.status}
					</span>

					<div class="flex shrink-0 items-center gap-1">
						{#if busyId === member.id}
							<span
								class="size-4 animate-spin rounded-full border-2 border-current border-t-transparent text-muted-foreground"
							></span>
						{:else if member.status === 'active' && !self}
							<select
								value={member.role}
								onchange={(event) =>
									changeRole(member, event.currentTarget.value as WorkspaceMemberRole)}
								class="rounded-md border border-input bg-secondary px-1.5 py-1 text-xs outline-none focus:border-primary/60"
								title="Change role"
								data-testid="workspace-member-role"
							>
								<option value="member">Member</option>
								<option value="admin">Admin</option>
							</select>
							<button
								type="button"
								class="inline-flex size-7 items-center justify-center rounded-md text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
								title="Transfer ownership"
								data-testid="workspace-member-transfer"
								onclick={() => transfer(member)}
							>
								<Crown class="size-4" />
							</button>
							<button
								type="button"
								class="inline-flex size-7 items-center justify-center rounded-md text-destructive transition-colors hover:bg-destructive/10"
								title="Remove member"
								data-testid="workspace-member-remove"
								onclick={() => remove(member)}
							>
								<UserMinus class="size-4" />
							</button>
						{:else if member.status === 'invited'}
							<button
								type="button"
								class="inline-flex size-7 items-center justify-center rounded-md text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
								title="Resend invite"
								data-testid="workspace-member-resend"
								onclick={() => resend(member)}
							>
								<Send class="size-4" />
							</button>
							<button
								type="button"
								class="inline-flex size-7 items-center justify-center rounded-md text-destructive transition-colors hover:bg-destructive/10"
								title="Revoke invite"
								data-testid="workspace-member-revoke"
								onclick={() => revoke(member)}
							>
								<X class="size-4" />
							</button>
						{/if}
					</div>
				</li>
			{/each}
		</ul>
	</SettingsSection>
</div>
