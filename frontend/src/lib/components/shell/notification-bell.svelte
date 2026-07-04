<script lang="ts">
	import { goto } from '$app/navigation';
	import { base } from '$app/paths';
	import { onMount } from 'svelte';
	import {
		AtSign,
		Bell,
		BellOff,
		CheckCircle,
		MessageSquare,
		RefreshCw,
		UserCheck,
		X
	} from '@lucide/svelte';
	import {
		groupNotifications,
		notificationTitle,
		type NotificationGroup,
		type NotificationItem
	} from '$lib/notifications';
	import { notificationFeed } from '$lib/stores/notifications.svelte';
	import { relativeTime } from '$lib/time';
	import * as DropdownMenu from '$lib/components/ui/dropdown-menu';
	import { sendUserMessage, trustSkill } from '$lib/ash/api';

	onMount(() => {
		void notificationFeed.loadInitial();
	});

	const groups = $derived(groupNotifications(notificationFeed.items));

	const ICONS: Record<string, typeof Bell> = {
		task_update: RefreshCw,
		task_completed: CheckCircle,
		mention: AtSign,
		message: MessageSquare,
		approval_request: UserCheck
	};

	function open(group: NotificationGroup) {
		notificationFeed.markRead(group.ids);
		const item = group.head;
		if (item.targetConversationId) {
			void goto(`${base}/chat/${item.targetConversationId}`);
		} else if (item.navigateTo) {
			// Custom links may point at classic-only routes; full navigation.
			window.location.href = item.navigateTo;
		}
	}

	/** Returns true when this notification should show the inline approval row. */
	function isApprovalRequest(item: NotificationItem): boolean {
		return (
			item.notificationType === 'approval_request' &&
			typeof item.metadata?.approve_phrase === 'string' &&
			item.metadata.approve_phrase.length > 0
		);
	}

	// Per-notification busy guard — maps notification id to approving state.
	let approving = $state<Record<string, boolean>>({});
	// "Always allow this skill" checkbox state, keyed by notification id.
	let trustChecked = $state<Record<string, boolean>>({});

	async function approve(item: NotificationItem) {
		if (approving[item.id]) return;
		const phrase = item.metadata?.approve_phrase;
		if (typeof phrase !== 'string' || !phrase) {
			notificationFeed.markRead([item.id]);
			return;
		}
		approving = { ...approving, [item.id]: true };
		try {
			const skillId = item.metadata?.skill_id;
			if (trustChecked[item.id] && skillId) {
				await trustSkill(String(skillId));
			}
			if (item.targetConversationId && phrase) {
				await sendUserMessage(item.targetConversationId, phrase, []);
			} else {
				console.warn('Skill approval notification missing target conversation or phrase', item.id);
			}
			notificationFeed.markRead([item.id]);
			if (item.targetConversationId) {
				void goto(`${base}/chat/${item.targetConversationId}`);
			}
		} finally {
			approving = { ...approving, [item.id]: false };
		}
	}

	function dismiss(item: NotificationItem) {
		notificationFeed.markRead([item.id]);
	}
</script>

<DropdownMenu.Root>
	<DropdownMenu.Trigger
		class="relative flex size-9 items-center justify-center rounded-lg text-muted-foreground transition-colors hover:bg-accent/60 hover:text-foreground"
		aria-label="Notifications"
		title="Notifications"
		data-testid="notification-bell"
	>
		<Bell class="size-5" />
		{#if notificationFeed.unreadCount > 0}
			<span
				class="absolute -right-0.5 -top-0.5 flex h-4 min-w-4 items-center justify-center rounded-full bg-primary px-1 text-[9px] font-semibold text-primary-foreground"
				data-testid="notification-badge"
			>
				{notificationFeed.unreadCount > 99 ? '99+' : notificationFeed.unreadCount}
			</span>
		{/if}
	</DropdownMenu.Trigger>
	<DropdownMenu.Content side="right" align="end" class="w-80 p-0">
		<div class="flex items-center justify-between border-b px-3 py-2">
			<p class="text-xs font-semibold uppercase tracking-wider text-muted-foreground">
				Notifications
			</p>
			{#if groups.length > 0}
				<button
					type="button"
					class="text-xs text-primary hover:underline"
					data-testid="mark-all-read"
					onclick={() => notificationFeed.markAllRead()}
				>
					Mark all as read
				</button>
			{/if}
		</div>

		<div class="wb-scroll max-h-96 overflow-y-auto" data-testid="notification-feed">
			{#if groups.length === 0}
				<div class="flex flex-col items-center gap-2 px-4 py-8 text-muted-foreground">
					<BellOff class="size-5" />
					<p class="text-xs">No unread notifications</p>
				</div>
			{:else}
				{#each groups as group (group.key)}
					{@const Icon = ICONS[group.head.notificationType] ?? Bell}
					<div class="group/note flex items-start gap-2.5 px-3 py-2.5 hover:bg-accent/40">
						<span
							class="mt-0.5 flex size-7 shrink-0 items-center justify-center rounded-full bg-secondary"
						>
							<Icon class="size-3.5 text-muted-foreground" />
						</span>
						{#if isApprovalRequest(group.head)}
							<div class="min-w-0 flex-1" data-testid="approval-card">
								<span class="block truncate text-sm font-medium">
									{notificationTitle(group.head)}
								</span>
								{#if group.head.body}
									<span class="block truncate text-xs text-muted-foreground">{group.head.body}</span
									>
								{/if}
								<span class="block text-[11px] text-muted-foreground">
									{#if group.head.insertedAt}{relativeTime(group.head.insertedAt)}{/if}
									{#if group.count > 1}
										<span class="text-primary">+{group.count - 1} more</span>
									{/if}
								</span>
								{#if Array.isArray(group.head.metadata?.declared_secret_keys) && group.head.metadata.declared_secret_keys.length > 0}
									<div class="mt-1 flex flex-wrap gap-1" data-testid="approval-declared-keys">
										{#each group.head.metadata.declared_secret_keys as key (key)}
											<span
												class="rounded bg-secondary px-1 py-px font-mono text-[9px] text-secondary-foreground"
												>{key}</span
											>
										{/each}
									</div>
								{/if}
								<label class="mt-1 flex items-center gap-1.5 text-[11px] text-muted-foreground">
									<input
										type="checkbox"
										bind:checked={trustChecked[group.head.id]}
										data-testid="approval-trust"
									/>
									Always allow this skill
								</label>
								<div class="mt-1.5 flex gap-1.5">
									<button
										type="button"
										class="rounded bg-primary px-2.5 py-0.5 text-[11px] font-medium text-primary-foreground transition-opacity hover:opacity-90 disabled:opacity-50"
										data-testid="approval-approve"
										disabled={approving[group.head.id] ?? false}
										onclick={() => approve(group.head)}
									>
										{approving[group.head.id] ? 'Approving…' : 'Approve'}
									</button>
									<button
										type="button"
										class="rounded border px-2.5 py-0.5 text-[11px] font-medium text-muted-foreground transition-colors hover:text-foreground"
										data-testid="approval-dismiss"
										onclick={() => dismiss(group.head)}
									>
										Dismiss
									</button>
								</div>
							</div>
						{:else}
							<button
								type="button"
								class="min-w-0 flex-1 text-left"
								data-testid="notification-row"
								onclick={() => open(group)}
							>
								<span class="block truncate text-sm font-medium">
									{notificationTitle(group.head)}
								</span>
								{#if group.head.body}
									<span class="block truncate text-xs text-muted-foreground">{group.head.body}</span
									>
								{/if}
								<span class="block text-[11px] text-muted-foreground">
									{#if group.head.insertedAt}{relativeTime(group.head.insertedAt)}{/if}
									{#if group.count > 1}
										<span class="text-primary">+{group.count - 1} more</span>
									{/if}
								</span>
							</button>
						{/if}
						<button
							type="button"
							class="mt-1 shrink-0 rounded p-0.5 text-muted-foreground opacity-0 transition-opacity hover:text-foreground group-hover/note:opacity-100"
							title="Mark as read"
							data-testid="notification-dismiss"
							onclick={() => notificationFeed.markRead(group.ids)}
						>
							<X class="size-3.5" />
						</button>
					</div>
				{/each}
			{/if}
		</div>
	</DropdownMenu.Content>
</DropdownMenu.Root>
