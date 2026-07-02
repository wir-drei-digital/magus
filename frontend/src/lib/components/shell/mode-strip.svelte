<script lang="ts">
	import { goto } from '$app/navigation';
	import { base } from '$app/paths';
	import { page } from '$app/state';
	import {
		ArrowLeftRight,
		BookOpen,
		Bot,
		Brain,
		Clock,
		Files,
		HelpCircle,
		LibraryBig,
		LogOut,
		MessageCircle,
		MessagesSquare,
		Monitor,
		Moon,
		Newspaper,
		Settings,
		Sun
	} from '@lucide/svelte';
	import { session } from '$lib/stores/session.svelte';
	import { workbench, type WorkbenchMode } from '$lib/stores/workbench.svelte';
	import * as DropdownMenu from '$lib/components/ui/dropdown-menu';
	import CreditIndicator from './credit-indicator.svelte';
	import NotificationBell from './notification-bell.svelte';

	const modes: { key: WorkbenchMode; label: string; icon: typeof MessagesSquare }[] = [
		{ key: 'chat', label: 'Chat', icon: MessagesSquare },
		{ key: 'brain', label: 'Brain', icon: Brain },
		{ key: 'files', label: 'Files', icon: Files },
		{ key: 'library', label: 'Library', icon: LibraryBig },
		{ key: 'agents', label: 'Agents', icon: Bot }
	];

	const MODE_HOME: Record<WorkbenchMode, string> = {
		chat: '/chat',
		brain: '/brain',
		files: '/files',
		library: '/library',
		agents: '/agents',
		// Legacy modes fold into Library; a saved session may still hold them.
		prompts: '/library',
		skills: '/library'
	};

	// Inside a mode view (/chat/*, /files/*, …) a mode click only swaps the nav
	// pane and keeps the open view (classic multi-pane parity). From a detour
	// route (settings, workspaces, history, jobs, search) there's no mode view
	// to keep, so the click navigates to that mode's home.
	function selectMode(mode: WorkbenchMode) {
		void workbench.setMode(mode);
		const rel = page.url.pathname.slice(base.length);
		const inModeView = /^\/(chat|brain|files|library|agents|prompts|skills)(\/|$)/.test(rel);
		if (!inModeView) void goto(`${base}${MODE_HOME[mode]}`);
	}

	const HELP_LINKS = [
		{ href: '/docs', label: 'Documentation', icon: BookOpen },
		{ href: '/help', label: 'Help & FAQ', icon: HelpCircle },
		{ href: '/blog', label: 'Blog', icon: Newspaper },
		{ href: '/support', label: 'Contact Support', icon: MessageCircle },
		{ href: 'https://discord.gg/6EfPDhmWRb', label: 'Discord Community', icon: MessagesSquare }
	];

	const initials = $derived(
		(session.user?.displayName ?? session.user?.email ?? '?').slice(0, 1).toUpperCase()
	);

	let toggling = $state(false);
	let theme = $state<'system' | 'light' | 'dark'>('system');

	$effect(() => {
		const stored = localStorage.getItem('phx:theme');
		theme = stored === 'light' || stored === 'dark' ? stored : 'system';
	});

	/** Same contract as the classic UI: the phx:theme localStorage key. */
	function setTheme(next: 'system' | 'light' | 'dark') {
		theme = next;
		if (next === 'system') localStorage.removeItem('phx:theme');
		else localStorage.setItem('phx:theme', next);

		const dark =
			next === 'dark' ||
			(next === 'system' && window.matchMedia('(prefers-color-scheme: dark)').matches);
		document.documentElement.classList.toggle('dark', dark);
	}

	async function backToClassic() {
		toggling = true;
		const ok = await session.setWorkbenchUi('classic');
		toggling = false;
		if (ok) window.location.href = '/chat';
	}
</script>

<nav
	class="flex w-14 shrink-0 flex-col items-center border-r bg-background"
	data-testid="mode-strip"
	aria-label="Modes"
>
	<!-- The classic rail's logo glyph (mode_strip.ex). -->
	<a
		href="{base}/chat"
		class="mb-2 mt-3 flex h-10 w-10 items-center justify-center text-[28px] leading-none text-primary transition-opacity hover:opacity-80"
		aria-label="Magus"
		title="Magus"
	>
		◬
	</a>

	<div class="flex flex-1 flex-col items-center gap-1.5 pt-2">
		{#each modes as mode (mode.key)}
			<!-- Mode switches swap only the nav pane; the open tab/view stays
			     (classic parity). Deep links into a mode's routes still sync
			     the nav via the routes' one-shot setMode effects. -->
			<button
				type="button"
				class="relative flex size-10 items-center justify-center rounded-lg transition-colors {workbench.mode ===
				mode.key
					? 'text-primary'
					: 'text-muted-foreground hover:bg-accent/60 hover:text-foreground'}"
				title={mode.label}
				data-testid="mode-{mode.key}"
				aria-current={workbench.mode === mode.key ? 'page' : undefined}
				onclick={() => selectMode(mode.key)}
			>
				{#if workbench.mode === mode.key}
					<span
						class="absolute -left-2 top-1/2 h-5 w-0.5 -translate-y-1/2 rounded-full bg-primary"
						aria-hidden="true"
					></span>
				{/if}
				<mode.icon class="size-[18px]" />
				<span class="sr-only">{mode.label}</span>
			</button>
		{/each}
	</div>

	<div class="flex flex-col items-center gap-1.5 pb-3" data-testid="mode-strip-footer">
		<CreditIndicator />
		<NotificationBell />

		<DropdownMenu.Root>
			<DropdownMenu.Trigger
				class="flex size-9 items-center justify-center rounded-lg text-muted-foreground transition-colors hover:bg-accent/60 hover:text-foreground"
				aria-label="Resources"
				title="Help & resources"
			>
				<HelpCircle class="size-5" />
			</DropdownMenu.Trigger>
			<DropdownMenu.Content side="right" align="end" class="w-52">
				{#each HELP_LINKS as link (link.href)}
					<DropdownMenu.Item>
						{#snippet child({ props })}
							<a
								{...props}
								href={link.href}
								target={link.href.startsWith('http') ? '_blank' : undefined}
								rel={link.href.startsWith('http') ? 'noopener noreferrer' : undefined}
								data-sveltekit-reload
							>
								<link.icon class="size-4" />
								{link.label}
							</a>
						{/snippet}
					</DropdownMenu.Item>
				{/each}
			</DropdownMenu.Content>
		</DropdownMenu.Root>

		<DropdownMenu.Root>
			<DropdownMenu.Trigger
				class="flex size-8 items-center justify-center rounded-full bg-secondary text-xs font-medium text-secondary-foreground transition-opacity hover:opacity-80"
				title={session.user?.displayName ?? session.user?.email ?? ''}
				data-testid="user-avatar"
			>
				{initials}
			</DropdownMenu.Trigger>
			<DropdownMenu.Content side="right" align="end" class="w-56">
				<div class="px-2 py-1.5">
					<p class="truncate text-sm font-medium">
						{session.user?.displayName ?? session.user?.email}
					</p>
					{#if session.user?.displayName}
						<p class="truncate text-xs text-muted-foreground">{session.user?.email}</p>
					{/if}
				</div>
				<DropdownMenu.Separator />
				<DropdownMenu.Item>
					{#snippet child({ props })}
						<a {...props} href="{base}/jobs">
							<Clock class="size-4" />
							Scheduled Jobs
						</a>
					{/snippet}
				</DropdownMenu.Item>
				<DropdownMenu.Item>
					{#snippet child({ props })}
						<a {...props} href="{base}/settings">
							<Settings class="size-4" />
							Settings
						</a>
					{/snippet}
				</DropdownMenu.Item>
				<DropdownMenu.Item onSelect={() => void backToClassic()} disabled={toggling}>
					<ArrowLeftRight class="size-4" />
					Switch to classic UI
				</DropdownMenu.Item>
				<DropdownMenu.Separator />
				<!-- Theme picker — same 3-option strip as classic. -->
				<div class="flex items-center gap-1 px-2 py-1.5" data-testid="theme-picker">
					{#each [{ key: 'system', icon: Monitor }, { key: 'light', icon: Sun }, { key: 'dark', icon: Moon }] as const as option (option.key)}
						<button
							type="button"
							class="flex flex-1 items-center justify-center rounded-md py-1 transition-colors {theme ===
							option.key
								? 'bg-secondary text-foreground'
								: 'text-muted-foreground hover:text-foreground'}"
							title={option.key}
							aria-label="{option.key} theme"
							aria-pressed={theme === option.key}
							onclick={() => setTheme(option.key)}
						>
							<option.icon class="size-4" />
						</button>
					{/each}
				</div>
				<DropdownMenu.Separator />
				<DropdownMenu.Item>
					{#snippet child({ props })}
						<a {...props} href="/sign-out" data-sveltekit-reload>
							<LogOut class="size-4" />
							Sign out
						</a>
					{/snippet}
				</DropdownMenu.Item>
			</DropdownMenu.Content>
		</DropdownMenu.Root>
	</div>
</nav>
