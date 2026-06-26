<script lang="ts">
	import { onMount } from 'svelte';
	import { Check, Copy, Link, Mail, UserMinus, Users, Volume2, VolumeOff } from '@lucide/svelte';
	import {
		cancelConversationInvitation,
		changeMemberRole,
		conversationInviteLinks,
		conversationMembers,
		createConversationInviteLink,
		deactivateConversationInviteLink,
		enableConversationMultiplayer,
		inviteToConversation,
		muteConversationMember,
		pendingConversationInvitations,
		removeConversationMember,
		unmuteConversationMember,
		type ConversationInvitationEntry,
		type ConversationMemberEntry,
		type InviteLinkEntry,
		type MemberRole
	} from '$lib/ash/api';
	import { session } from '$lib/stores/session.svelte';
	import { workbench } from '$lib/stores/workbench.svelte';
	import * as DropdownMenu from '$lib/components/ui/dropdown-menu';

	let { conversationId }: { conversationId: string } = $props();

	const conversation = $derived(workbench.conversation(conversationId));

	let members = $state<ConversationMemberEntry[]>([]);
	let invitations = $state<ConversationInvitationEntry[]>([]);
	let links = $state<InviteLinkEntry[]>([]);
	let loading = $state(true);
	let error = $state<string | null>(null);
	let busy = $state(false);
	let copiedId = $state<string | null>(null);
	let confirmingRemoveId = $state<string | null>(null);

	let inviteEmail = $state('');
	let inviteRole = $state<Exclude<MemberRole, 'owner'>>('member');

	// Management actions are the owner's; the server enforces it — this only
	// decides what to render.
	const isOwner = $derived(
		members.some((member) => member.role === 'owner' && member.user.id === session.user?.id)
	);

	onMount(() => {
		void refresh();
	});

	async function refresh() {
		if (!conversation?.isMultiplayer) {
			loading = false;
			return;
		}
		const [membersResult, invitationsResult, linksResult] = await Promise.all([
			conversationMembers(conversationId),
			pendingConversationInvitations(conversationId),
			conversationInviteLinks(conversationId)
		]);
		if (membersResult.success) members = membersResult.data;
		if (invitationsResult.success) invitations = invitationsResult.data;
		if (linksResult.success) links = linksResult.data;
		loading = false;
	}

	async function enableCollaboration() {
		busy = true;
		const result = await enableConversationMultiplayer(conversationId);
		busy = false;
		if (result.success) {
			workbench.upsertConversation(result.data);
			loading = true;
			await refresh();
		}
	}

	function memberName(member: ConversationMemberEntry): string {
		return member.user.displayName || member.user.email;
	}

	async function invite() {
		const email = inviteEmail.trim();
		if (!email || busy) return;
		busy = true;
		error = null;
		const result = await inviteToConversation({ conversationId, email, role: inviteRole });
		busy = false;
		if (result.success) {
			invitations = [result.data, ...invitations];
			inviteEmail = '';
		} else {
			error = result.errors[0]?.message ?? 'Invitation failed';
		}
	}

	async function cancelInvitation(id: string) {
		const result = await cancelConversationInvitation(id);
		if (result.success) invitations = invitations.filter((entry) => entry.id !== id);
	}

	async function setRole(member: ConversationMemberEntry, role: Exclude<MemberRole, 'owner'>) {
		const result = await changeMemberRole(member.id, role);
		if (result.success) {
			members = members.map((entry) => (entry.id === member.id ? result.data : entry));
		}
	}

	async function toggleMute(member: ConversationMemberEntry) {
		const result = member.isMuted
			? await unmuteConversationMember(member.id)
			: await muteConversationMember(member.id);
		if (result.success) {
			members = members.map((entry) => (entry.id === member.id ? result.data : entry));
		}
	}

	async function removeMember(member: ConversationMemberEntry) {
		if (confirmingRemoveId !== member.id) {
			confirmingRemoveId = member.id;
			setTimeout(() => {
				if (confirmingRemoveId === member.id) confirmingRemoveId = null;
			}, 3000);
			return;
		}
		confirmingRemoveId = null;
		const result = await removeConversationMember(member.id);
		if (result.success) members = members.filter((entry) => entry.id !== member.id);
	}

	function joinUrl(link: InviteLinkEntry): string {
		return `${location.origin}/chat/join/${link.token}`;
	}

	async function copyLink(link: InviteLinkEntry) {
		try {
			await navigator.clipboard.writeText(joinUrl(link));
			copiedId = link.id;
			setTimeout(() => (copiedId = copiedId === link.id ? null : copiedId), 1500);
		} catch {
			// Clipboard denied — the URL is in the title attribute.
		}
	}

	async function createLink() {
		if (busy) return;
		busy = true;
		const result = await createConversationInviteLink({ conversationId, role: 'member' });
		busy = false;
		if (result.success) links = [result.data, ...links];
	}

	async function deactivateLink(id: string) {
		const result = await deactivateConversationInviteLink(id);
		if (result.success) links = links.filter((entry) => entry.id !== id);
	}
</script>

<div class="flex min-h-0 flex-1 flex-col" data-testid="members-panel">
	<header class="flex shrink-0 items-center gap-2 border-b px-3 py-2">
		<Users class="size-4 text-muted-foreground" />
		<h3 class="text-sm font-medium">Members</h3>
	</header>

	<div class="wb-scroll min-h-0 flex-1 overflow-y-auto p-3">
		{#if !conversation?.isMultiplayer}
			<div class="flex flex-col items-start gap-2 py-2">
				<p class="text-xs text-muted-foreground">
					Collaboration is off — enable it to invite participants into this conversation.
				</p>
				<button
					type="button"
					class="wb-pill-btn"
					data-testid="members-enable-collaboration"
					disabled={busy}
					onclick={() => void enableCollaboration()}
				>
					<Users class="size-3.5" />
					<span>Enable collaboration</span>
				</button>
			</div>
		{:else if loading}
			<!-- Quiet load. -->
		{:else}
			<ul class="flex flex-col gap-1" data-testid="members-list">
				{#each members as member (member.id)}
					<li class="flex items-center gap-2 rounded-lg px-2 py-1.5 hover:bg-accent/40">
						<span
							class="flex size-7 shrink-0 items-center justify-center rounded-full border border-input bg-secondary text-[10px] font-medium uppercase"
						>
							{memberName(member).slice(0, 2)}
						</span>
						<span class="min-w-0 flex-1">
							<span class="block truncate text-xs font-medium">
								{memberName(member)}
								{#if member.user.id === session.user?.id}
									<span class="text-muted-foreground">(you)</span>
								{/if}
							</span>
							<span class="block text-[10px] text-muted-foreground capitalize">
								{member.role}{member.isMuted ? ' · muted' : ''}
								{member.acceptedAt ? '' : ' · invited'}
							</span>
						</span>
						{#if isOwner && member.role !== 'owner'}
							<DropdownMenu.Root>
								<DropdownMenu.Trigger
									class="wb-pill-btn shrink-0 capitalize"
									data-testid="member-role"
								>
									{member.role}
								</DropdownMenu.Trigger>
								<DropdownMenu.Content align="end">
									<DropdownMenu.Item onSelect={() => void setRole(member, 'member')}>
										Member — can write
									</DropdownMenu.Item>
									<DropdownMenu.Item onSelect={() => void setRole(member, 'observer')}>
										Observer — read only
									</DropdownMenu.Item>
								</DropdownMenu.Content>
							</DropdownMenu.Root>
							<button
								type="button"
								class="wb-pill-btn wb-pill-btn-square shrink-0"
								title={member.isMuted ? 'Unmute' : 'Mute'}
								data-testid="member-mute"
								onclick={() => void toggleMute(member)}
							>
								{#if member.isMuted}<VolumeOff class="size-3.5" />{:else}<Volume2
										class="size-3.5"
									/>{/if}
							</button>
							<button
								type="button"
								class="wb-pill-btn wb-pill-btn-square shrink-0 {confirmingRemoveId === member.id
									? '!border-destructive !bg-destructive !text-destructive-foreground'
									: 'hover:!text-destructive'}"
								title={confirmingRemoveId === member.id ? 'Confirm remove' : 'Remove'}
								data-testid="member-remove"
								onclick={() => void removeMember(member)}
							>
								<UserMinus class="size-3.5" />
							</button>
						{/if}
					</li>
				{/each}
			</ul>

			{#if isOwner}
				<form
					class="mt-3 flex items-center gap-1.5"
					onsubmit={(event) => {
						event.preventDefault();
						void invite();
					}}
				>
					<input
						type="email"
						bind:value={inviteEmail}
						placeholder="Invite by email…"
						data-testid="member-invite-email"
						class="min-w-0 flex-1 rounded-md border border-input bg-secondary px-2 py-1.5 text-xs outline-none placeholder:text-muted-foreground focus:border-primary/60"
					/>
					<select
						bind:value={inviteRole}
						class="shrink-0 rounded-md border border-input bg-secondary px-1.5 py-[5px] text-xs outline-none"
						aria-label="Role"
					>
						<option value="member">Member</option>
						<option value="observer">Observer</option>
					</select>
					<button
						type="submit"
						class="wb-pill-btn shrink-0"
						data-testid="member-invite-submit"
						disabled={busy || inviteEmail.trim() === ''}
					>
						<Mail class="size-3.5" />
						<span>Invite</span>
					</button>
				</form>
				{#if error}
					<p class="mt-1 text-xs text-destructive">{error}</p>
				{/if}

				{#if invitations.length > 0}
					<p
						class="mt-3 mb-1 font-mono text-[10px] font-medium tracking-wider text-muted-foreground uppercase"
					>
						Pending invitations
					</p>
					<ul class="flex flex-col gap-1" data-testid="pending-invitations">
						{#each invitations as invitation (invitation.id)}
							<li class="flex items-center gap-2 rounded-lg px-2 py-1 text-xs">
								<Mail class="size-3.5 shrink-0 text-muted-foreground" />
								<span class="min-w-0 flex-1 truncate">{invitation.email}</span>
								<span class="shrink-0 text-[10px] text-muted-foreground capitalize">
									{invitation.role}
								</span>
								<button
									type="button"
									class="wb-pill-btn shrink-0 hover:!text-destructive"
									data-testid="invitation-cancel"
									onclick={() => void cancelInvitation(invitation.id)}
								>
									Cancel
								</button>
							</li>
						{/each}
					</ul>
				{/if}

				<div class="mt-3 flex items-center justify-between">
					<p class="font-mono text-[10px] font-medium tracking-wider text-muted-foreground uppercase">
						Invite links
					</p>
					<button
						type="button"
						class="wb-pill-btn shrink-0"
						data-testid="invite-link-create"
						disabled={busy}
						onclick={() => void createLink()}
					>
						<Link class="size-3.5" />
						<span>New link</span>
					</button>
				</div>
				{#if links.length > 0}
					<ul class="mt-1 flex flex-col gap-1" data-testid="invite-link-list">
						{#each links as link (link.id)}
							<li
								class="flex items-center gap-2 rounded-lg border border-input px-2 py-1.5 text-xs"
							>
								<Link class="size-3.5 shrink-0 text-muted-foreground" />
								<span class="min-w-0 flex-1 truncate text-[10px] text-muted-foreground">
									{joinUrl(link)}
								</span>
								<span class="shrink-0 text-[10px] text-muted-foreground capitalize">
									{link.role}
								</span>
								<button
									type="button"
									class="wb-pill-btn wb-pill-btn-square shrink-0 {copiedId === link.id
										? '!text-success'
										: ''}"
									title="Copy join link"
									data-testid="invite-link-copy"
									onclick={() => void copyLink(link)}
								>
									{#if copiedId === link.id}<Check class="size-3.5" />{:else}<Copy
											class="size-3.5"
										/>{/if}
								</button>
								<button
									type="button"
									class="wb-pill-btn shrink-0 hover:!text-destructive"
									data-testid="invite-link-deactivate"
									onclick={() => void deactivateLink(link.id)}
								>
									Revoke
								</button>
							</li>
						{/each}
					</ul>
				{/if}
			{/if}
		{/if}
	</div>
</div>
