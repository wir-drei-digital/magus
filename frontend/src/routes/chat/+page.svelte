<script lang="ts">
	import { page } from '$app/state';
	import { goto } from '$app/navigation';
	import { base } from '$app/paths';
	import { workbench } from '$lib/stores/workbench.svelte';
	import { cachedMyAgents } from '$lib/chat/catalog';
	import {
		getCustomAgent,
		getPrompt,
		incrementPromptUseCount,
		type AgentDetail
	} from '$lib/ash/api';
	import LandingComposer from '$lib/components/chat/landing-composer.svelte';
	import AnnouncementsSection from '$lib/components/chat/announcements-section.svelte';
	import OpenTasksSection from '$lib/components/chat/open-tasks-section.svelte';
	import OnboardingCardsSection from '$lib/components/chat/onboarding-cards-section.svelte';

	// One-shot: deep links / logo clicks sync the nav to chat mode once;
	// afterwards the mode strip may switch the nav freely without this route
	// forcing it back (matches the other mode routes).
	let modeSynced = false;
	$effect(() => {
		if (modeSynced || !workbench.session) return;
		modeSynced = true;
		if (workbench.mode !== 'chat') void workbench.setMode('chat');
	});

	// Returning users get a softer prompt; brand-new accounts (no conversations
	// yet) get the exploratory one — classic first_time? parity, approximated.
	const firstTime = $derived(workbench.conversations.length === 0);

	// One-shot spin on hover: armed here, cleared on animationend (matches the
	// classic MagusLogo hook so the spin completes even if the pointer leaves).
	let spinning = $state(false);

	// Classic ?agent= / ?use_prompt= deeplinks (UrlActions): seed the landing
	// composer with a custom agent (indicator + slash commands + customAgentId)
	// or a user prompt's content. Both resolve reactively from the URL.
	type LandingAgent = Pick<AgentDetail, 'id' | 'name' | 'icon' | 'imageUrl'>;
	const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

	const agentParam = $derived(page.url.searchParams.get('agent'));
	const promptParam = $derived(page.url.searchParams.get('use_prompt'));

	let agent = $state<LandingAgent | null>(null);
	$effect(() => {
		const param = agentParam;
		agent = null;
		if (!param) return;
		// UUID → any accessible agent; bare handle → one of the actor's own.
		if (UUID_RE.test(param)) {
			void getCustomAgent(param).then((result) => {
				if (result.success && agentParam === param) agent = result.data;
			});
		} else {
			void cachedMyAgents().then((result) => {
				if (result.success && agentParam === param) {
					agent = result.data.find((entry) => entry.handle === param) ?? null;
				}
			});
		}
	});

	let seedText = $state<string | null>(null);
	$effect(() => {
		const param = promptParam;
		seedText = null;
		if (!param) return;
		void getPrompt(param).then((result) => {
			// System prompts need activation on a live conversation (no SPA RPC
			// yet); only user prompts seed the composer text here.
			if (result.success && result.data.type === 'user' && promptParam === param) {
				seedText = result.data.content;
				void incrementPromptUseCount(param);
			}
		});
	});

	// Classic ?skill= deeplink: create the skill-seeded conversation server-side
	// and redirect to it (the composer is skipped — the start message is sent
	// for the user). Drives the onboarding "Try it out" cards.
	const skillParam = $derived(page.url.searchParams.get('skill'));
	let startingSkill = $state(false);
	$effect(() => {
		const skill = skillParam;
		if (!skill || startingSkill || !workbench.session) return;
		startingSkill = true;
		const topic = page.url.searchParams.get('topic');
		void workbench.startSkillConversation({ skillName: skill, topic }).then((conversation) => {
			if (conversation) {
				void goto(`${base}/chat/${conversation.id}`);
			} else {
				// Unknown skill / failure: fall back to the normal landing.
				startingSkill = false;
			}
		});
	});
</script>

<svelte:head>
	<title>Magus — Chat</title>
</svelte:head>

<div class="flex h-full flex-col items-center justify-center overflow-y-auto px-4">
	<div class="w-full max-w-3xl py-10">
		<div class="mb-4 flex justify-center">
			<span
				class="magus-logo-animated cursor-default text-6xl leading-none text-primary select-none"
				class:is-spinning={spinning}
				data-testid="new-chat-logo"
				aria-hidden="true"
				onmouseenter={() => (spinning = true)}
				onanimationend={(event) => {
					if (event.animationName === 'magus-spin') spinning = false;
				}}
			>
				◬
			</span>
		</div>

		{#if startingSkill}
			<p
				class="flex items-center justify-center gap-2 text-center text-sm text-muted-foreground"
				data-testid="new-chat-starting-skill"
			>
				<span
					class="size-3.5 animate-spin rounded-full border-2 border-current border-t-transparent"
				></span>
				Starting…
			</p>
		{:else}
			<p
				class="mb-6 text-center font-display text-3xl font-semibold tracking-tight text-foreground"
				data-testid="new-chat-greeting"
			>
				{firstTime ? 'What would you like to explore?' : "What's on your mind?"}
			</p>

			<!-- Classic new-chat parity: announcements, then actionable + discovery
			     sections, between the greeting and the composer. Each renders
			     nothing when empty. -->
			<AnnouncementsSection />
			<OpenTasksSection />
			<OnboardingCardsSection />

			<LandingComposer {agent} {seedText} />
		{/if}
	</div>
</div>
