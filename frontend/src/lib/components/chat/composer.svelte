<script lang="ts">
	import { onMount, untrack } from 'svelte';
	import {
		ArrowRight,
		Bell,
		Bot,
		Brain,
		FileText,
		Film,
		Globe,
		Image,
		Paperclip,
		Plus,
		Square,
		SquareSlash,
		SquareTerminal,
		Users
	} from '@lucide/svelte';
	import {
		chatFeatureLimits,
		deleteFile,
		setConversationImageModel,
		setConversationMode,
		setConversationModel,
		setConversationVideoModel,
		updateConversationImageSettings,
		updateConversationVideoSettings,
		uploadFile,
		type AgentSummary,
		type ChatFeatureLimits,
		type ChatMode,
		type ModelSummary,
		type SlashCommandEntry,
		type UploadedFile
	} from '$lib/ash/api';
	import { cachedActiveModels, cachedMyAgents, cachedSlashCommands } from '$lib/chat/catalog';
	import { imageModalityMismatch } from '$lib/chat/composer-guards';
	import type { ConversationStore } from '$lib/chat/conversation-store.svelte';
	import { isConversationOwner } from '$lib/chat/ownership';
	import { clearDraft, loadDraft, saveDraft } from '$lib/chat/drafts';
	import {
		detectMention,
		filterAgents,
		insertMention,
		type MentionContext
	} from '$lib/chat/mentions';
	import { workbench } from '$lib/stores/workbench.svelte';
	import { session } from '$lib/stores/session.svelte';
	import * as DropdownMenu from '$lib/components/ui/dropdown-menu';
	import GenerationConfig from './generation-config.svelte';
	import ModelPicker from './model-picker.svelte';
	import ModeToggles from './mode-toggles.svelte';
	import type { ImageGenSettings, VideoGenSettings } from '$lib/chat/generation-config';
	import PromptPickerDialog from './prompt-picker-dialog.svelte';
	import ContextIndicator from './context-indicator.svelte';

	let { store }: { store: ConversationStore } = $props();

	// Captured once at mount: the route reassigns its reactive `store` during a
	// conversation switch, which can briefly point this (dying) instance at the
	// next conversation. Persisting drafts against the live `store.conversationId`
	// then flushes one conversation's text under another's key. This instance is
	// keyed per conversation, so a fixed id is always the right draft key.
	const draftKey = untrack(() => store.conversationId);

	let value = $state('');
	let textarea = $state<HTMLTextAreaElement | null>(null);
	let fileInput = $state<HTMLInputElement | null>(null);

	let attachments = $state<UploadedFile[]>([]);
	let uploading = $state(0);
	let uploadError = $state<string | null>(null);

	let agents = $state<AgentSummary[]>([]);
	let models = $state<ModelSummary[]>([]);
	let featureLimits = $state<ChatFeatureLimits | null>(null);
	let mention = $state<MentionContext | null>(null);
	let mentionIndex = $state(0);

	let promptPickerOpen = $state(false);

	function insertPromptContent(content: string) {
		const cursor = textarea?.selectionStart ?? value.length;
		value = value.slice(0, cursor) + content + value.slice(cursor);
		textarea?.focus();
		requestAnimationFrame(autoGrow);
		if (draftTimer) clearTimeout(draftTimer);
		draftTimer = setTimeout(() => saveDraft(localStorage, draftKey, value), 400);
	}

	// Right-rail prompt inserts arrive through the store (the rail lives in the
	// header, outside this subtree). Revision-armed against re-runs.
	let insertSeen = 0;
	$effect(() => {
		const request = store.insertTextRequest;
		if (request.revision === insertSeen) return;
		insertSeen = request.revision;
		insertPromptContent(request.text);
	});

	const conversation = $derived(workbench.conversation(store.conversationId));
	const chatMode = $derived(conversation?.chatMode ?? 'chat');
	// Owner-only context-window controls (Clear/Compact/strategy); non-owner members
	// get a read-only donut, mirroring the classic is_owner gate. Server enforces.
	const isOwner = $derived(isConversationOwner(conversation, session.user?.id));

	// Plus-menu slash commands: globals merged with the active agent's own.
	let slashCommands = $state<SlashCommandEntry[]>([]);

	const SLASH_ICONS: Record<string, typeof Globe> = {
		'lucide-globe': Globe,
		'lucide-bell': Bell,
		'lucide-file-text': FileText,
		'lucide-brain': Brain,
		'lucide-users': Users
	};

	$effect(() => {
		const agentId = conversation?.customAgentId ?? null;
		void cachedSlashCommands(agentId).then((result) => {
			if (result.success) slashCommands = result.data;
		});
	});

	/** Classic inject_slash_command: prepend "/name " and focus. */
	function injectSlashCommand(name: string) {
		value = `/${name} ` + value;
		textarea?.focus();
		requestAnimationFrame(autoGrow);
	}
	const suggestions = $derived(mention ? filterAgents(agents, mention.query) : []);
	const mentionOpen = $derived(mention !== null && suggestions.length > 0);

	// Block sending an image to a model that can't read images (classic
	// has_modality_mismatch?); Auto/unknown models never block.
	const selectedModel = $derived(models.find((model) => model.id === selectedModelForMode) ?? null);
	const modalityMismatch = $derived(imageModalityMismatch(attachments, selectedModel));

	const canSend = $derived(
		value.trim().length > 0 &&
			!store.sending &&
			!store.accessRevoked &&
			uploading === 0 &&
			!modalityMismatch &&
			// Send-lock parity with the LiveView composer: an in-flight compaction
			// blocks new turns until the window settles.
			!store.compactionInProgress
	);

	// Drag-and-drop file drop zone (in addition to paste + the picker button).
	let dragging = $state(false);
	function onDragOver(event: DragEvent) {
		if (!event.dataTransfer?.types.includes('Files')) return;
		event.preventDefault();
		dragging = true;
	}
	function onDragLeave(event: DragEvent) {
		// Ignore leaves into child elements (relatedTarget still inside the card).
		if (event.currentTarget instanceof Node && event.relatedTarget instanceof Node) {
			if (event.currentTarget.contains(event.relatedTarget)) return;
		}
		dragging = false;
	}
	function onDrop(event: DragEvent) {
		const files = event.dataTransfer?.files;
		if (!files || files.length === 0) return;
		event.preventDefault();
		dragging = false;
		void attach(files);
	}

	let draftTimer: ReturnType<typeof setTimeout> | null = null;

	onMount(() => {
		value = loadDraft(localStorage, draftKey);
		void cachedMyAgents().then((result) => {
			if (result.success) agents = result.data;
		});
		void cachedActiveModels().then((result) => {
			if (result.success) models = result.data;
		});
		void chatFeatureLimits().then((result) => {
			if (result.success) featureLimits = result.data;
		});
		return () => {
			if (draftTimer) clearTimeout(draftTimer);
			// Flush on unmount — keystrokes within the debounce window would
			// otherwise be lost on a fast conversation switch. saveDraft treats
			// empty text as a remove, so a cleared composer clears the key.
			saveDraft(localStorage, draftKey, value);
			// Attachment chips don't survive a remount, so never-sent uploads
			// are discarded with them (skipped mid-send: the message may
			// already reference these files).
			if (!store.sending) {
				for (const file of attachments) void deleteFile(file.id);
			}
		};
	});

	// Auto-grow up to a cap, then scroll inside the textarea.
	function autoGrow() {
		if (!textarea) return;
		textarea.style.height = 'auto';
		textarea.style.height = `${Math.min(textarea.scrollHeight, 320)}px`;
	}

	function onInput() {
		autoGrow();
		store.notifyTyping();
		refreshMention();

		if (draftTimer) clearTimeout(draftTimer);
		draftTimer = setTimeout(() => saveDraft(localStorage, draftKey, value), 400);
	}

	function refreshMention() {
		const caret = textarea?.selectionStart ?? value.length;
		const next = detectMention(value, caret);
		if (next?.start !== mention?.start || next?.query !== mention?.query) mentionIndex = 0;
		mention = next;
	}

	function pickMention(agent: AgentSummary) {
		if (!mention || !textarea) return;
		const caret = textarea.selectionStart ?? value.length;
		const result = insertMention(value, caret, mention, agent.handle);
		value = result.text;
		mention = null;
		// Restore focus + caret after Svelte applies the bound value.
		requestAnimationFrame(() => {
			textarea?.focus();
			textarea?.setSelectionRange(result.caret, result.caret);
			autoGrow();
		});
	}

	async function attach(files: FileList | File[]) {
		uploadError = null;
		const list = Array.from(files);
		uploading += list.length;

		for (const file of list) {
			const result = await uploadFile(file, store.conversationId);
			uploading -= 1;
			if (result.success) {
				attachments = [...attachments, result.data];
			} else {
				uploadError = result.errors[0]?.message ?? 'Upload failed';
			}
		}
	}

	function onPaste(event: ClipboardEvent) {
		const files = event.clipboardData?.files;
		if (files && files.length > 0) {
			event.preventDefault();
			void attach(files);
		}
	}

	function removeAttachment(id: string) {
		attachments = attachments.filter((file) => file.id !== id);
		// The chip's file was uploaded just for this message; removing the
		// chip discards it entirely so it doesn't orphan storage quota.
		void deleteFile(id);
	}

	/** Image/film toggles flip chat_mode to/from the generation modes. */
	async function toggleMode(mode: ChatMode) {
		// Defensive: the toggle is disabled when the plan disallows it, but never
		// enter a mode the backend would reject.
		if (mode === 'image_generation' && featureLimits && !featureLimits.imageGenerationEnabled)
			return;
		if (mode === 'video_generation' && featureLimits && !featureLimits.videoGenerationEnabled)
			return;
		const next = chatMode === mode ? 'chat' : mode;
		const result = await setConversationMode(store.conversationId, next);
		if (result.success) workbench.upsertConversation(result.data);
	}

	// The picker shows (and writes) the model for the active mode: image/video
	// generation each have their own model field, distinct from the chat model.
	const selectedModelForMode = $derived(
		chatMode === 'image_generation'
			? (conversation?.selectedImageModelId ?? null)
			: chatMode === 'video_generation'
				? (conversation?.selectedVideoModelId ?? null)
				: (conversation?.selectedModelId ?? null)
	);

	async function pickModel(modelId: string | null) {
		const result =
			chatMode === 'image_generation'
				? await setConversationImageModel(store.conversationId, modelId)
				: chatMode === 'video_generation'
					? await setConversationVideoModel(store.conversationId, modelId)
					: await setConversationModel(store.conversationId, modelId);
		if (result.success) workbench.upsertConversation(result.data);
	}

	async function applyImageSettings(settings: ImageGenSettings) {
		const result = await updateConversationImageSettings(store.conversationId, settings);
		if (result.success) workbench.upsertConversation(result.data);
	}

	async function applyVideoSettings(settings: VideoGenSettings) {
		const result = await updateConversationVideoSettings(store.conversationId, settings);
		if (result.success) workbench.upsertConversation(result.data);
	}

	async function submit() {
		if (!canSend) return;
		const text = value;
		const resources = attachments.map((file) => ({ type: 'file' as const, id: file.id }));
		value = '';
		mention = null;
		autoGrow();

		const sent = await store.send(text, resources);
		if (sent) {
			attachments = [];
			clearDraft(localStorage, draftKey);
		} else {
			// Keep the user's words (and attachments) on failure so they can retry.
			value = text;
			autoGrow();
		}
		textarea?.focus();
	}

	function onKeydown(event: KeyboardEvent) {
		if (mentionOpen) {
			if (event.key === 'ArrowDown') {
				event.preventDefault();
				mentionIndex = (mentionIndex + 1) % suggestions.length;
				return;
			}
			if (event.key === 'ArrowUp') {
				event.preventDefault();
				mentionIndex = (mentionIndex - 1 + suggestions.length) % suggestions.length;
				return;
			}
			if (event.key === 'Enter' || event.key === 'Tab') {
				event.preventDefault();
				pickMention(suggestions[mentionIndex]);
				return;
			}
			if (event.key === 'Escape') {
				event.preventDefault();
				mention = null;
				return;
			}
		}

		if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) {
			event.preventDefault();
			void submit();
		}
	}
</script>

<div class="mx-auto w-full max-w-3xl">
	{#if store.sendError || uploadError}
		<p
			class="pb-1 text-xs text-destructive"
			role="alert"
			id="composer-error"
			data-testid="composer-error"
		>
			{store.sendError ?? uploadError}
		</p>
	{/if}

	{#if modalityMismatch}
		<p class="pb-1 text-xs text-warning" role="alert" data-testid="composer-modality-warning">
			The selected model can't read images. Pick an image-capable model or remove the image.
		</p>
	{/if}

	{#if attachments.length > 0 || uploading > 0}
		<div class="flex flex-wrap gap-1.5 pb-1.5" data-testid="composer-attachments">
			{#each attachments as file (file.id)}
				<span
					class="inline-flex items-center gap-1.5 rounded-full border border-input bg-secondary px-2.5 py-0.5 text-xs text-secondary-foreground"
				>
					<span class="max-w-40 truncate">{file.name}</span>
					<button
						type="button"
						class="-mr-1 inline-flex size-5 items-center justify-center rounded text-muted-foreground hover:text-foreground"
						aria-label="Remove attachment {file.name}"
						onclick={() => removeAttachment(file.id)}
					>
						×
					</button>
				</span>
			{/each}
			{#if uploading > 0}
				<span class="inline-flex items-center gap-1.5 px-2 py-0.5 text-xs text-muted-foreground">
					<span
						class="size-3 animate-spin rounded-full border-2 border-current border-t-transparent"
					></span>
					Uploading…
				</span>
			{/if}
		</div>
	{/if}

	<div class="relative">
		{#if mentionOpen}
			<div
				class="absolute bottom-full left-0 z-10 mb-1 w-72 overflow-hidden rounded-lg border bg-popover py-1 text-popover-foreground shadow-md"
				data-testid="mention-dropdown"
			>
				{#each suggestions as agent, index (agent.id)}
					<button
						type="button"
						class="flex w-full items-center gap-2 px-3 py-1.5 text-left text-sm {index ===
						mentionIndex
							? 'bg-accent text-accent-foreground'
							: 'hover:bg-accent/60'}"
						data-testid="mention-option"
						onmousedown={(event) => {
							event.preventDefault();
							pickMention(agent);
						}}
					>
						<span aria-hidden="true">
							{#if agent.icon}{agent.icon}{:else}<Bot class="size-3.5" />{/if}
						</span>
						<span class="min-w-0">
							<span class="block truncate font-medium">@{agent.handle}</span>
							<span class="block truncate text-xs text-muted-foreground">{agent.name}</span>
						</span>
					</button>
				{/each}
			</div>
		{/if}

		<!-- Classic .chat-input-card: one large surface-2 card holding the
		     textarea plus a footer row of controls. Doubles as a file drop zone. -->
		<div
			role="group"
			class="composer-surface relative rounded-2xl border bg-secondary {dragging
				? 'border-primary border-dashed'
				: 'border-input'}"
			ondragover={onDragOver}
			ondragleave={onDragLeave}
			ondrop={onDrop}
		>
			{#if dragging}
				<div
					class="pointer-events-none absolute inset-0 z-10 flex items-center justify-center rounded-2xl bg-primary/10 text-sm font-medium text-primary"
					data-testid="composer-dropzone"
				>
					Drop files to attach
				</div>
			{/if}
			<textarea
				bind:this={textarea}
				bind:value
				oninput={onInput}
				onkeydown={onKeydown}
				onpaste={onPaste}
				onclick={refreshMention}
				onblur={() => store.stopTyping()}
				rows="1"
				placeholder={store.accessRevoked
					? 'Access revoked'
					: 'Type your message... (Enter to send, Shift+Enter for new line)'}
				disabled={store.accessRevoked}
				aria-describedby={store.sendError || uploadError ? 'composer-error' : undefined}
				data-testid="composer-input"
				class="max-h-[320px] min-h-[72px] w-full resize-none bg-transparent px-4 pt-3 text-sm outline-none placeholder:text-muted-foreground disabled:cursor-not-allowed disabled:opacity-50"
			></textarea>

			<div class="flex items-center gap-1 px-2.5 pb-2">
				<DropdownMenu.Root>
					<DropdownMenu.Trigger
						class="inline-flex size-8 items-center justify-center rounded-lg text-muted-foreground transition-colors hover:bg-accent hover:text-foreground max-md:size-10"
						data-testid="composer-actions"
						aria-label="Actions"
					>
						<Plus class="size-[18px]" />
					</DropdownMenu.Trigger>
					<DropdownMenu.Content align="start" class="w-72">
						<DropdownMenu.Item onSelect={() => fileInput?.click()}>
							<Paperclip class="size-4" />
							Attach file
						</DropdownMenu.Item>
						<DropdownMenu.Item
							data-testid="composer-insert-prompt"
							onSelect={() => (promptPickerOpen = true)}
						>
							<SquareTerminal class="size-4" />
							Insert prompt
						</DropdownMenu.Item>
						<!-- Image/video generation, surfaced in the menu on mobile where the
						     inline footer toggles are hidden for space. -->
						{#if featureLimits?.imageGenerationEnabled ?? true}
							<DropdownMenu.Item
								class="md:hidden"
								data-testid="composer-menu-image"
								onSelect={() => void toggleMode('image_generation')}
							>
								<Image class="size-4" />
								Image generation
							</DropdownMenu.Item>
						{/if}
						{#if featureLimits?.videoGenerationEnabled ?? true}
							<DropdownMenu.Item
								class="md:hidden"
								data-testid="composer-menu-video"
								onSelect={() => void toggleMode('video_generation')}
							>
								<Film class="size-4" />
								Video generation
							</DropdownMenu.Item>
						{/if}
						{#if slashCommands.length > 0}
							<DropdownMenu.Separator />
							{#each slashCommands as command (command.name)}
								{@const Icon = SLASH_ICONS[command.icon ?? ''] ?? SquareSlash}
								<DropdownMenu.Item
									data-testid="composer-slash-command"
									onSelect={() => injectSlashCommand(command.name)}
								>
									<Icon class="size-4" />
									<span class="flex-1">{command.title}</span>
									<span class="ml-2 text-xs font-normal text-muted-foreground">/{command.name}</span
									>
								</DropdownMenu.Item>
							{/each}
						{/if}
					</DropdownMenu.Content>
				</DropdownMenu.Root>

				<!-- Inline toggles on md+; on mobile these live in the + menu above. -->
				<div class="flex items-center gap-1 max-md:hidden">
					<ModeToggles
						{chatMode}
						imageEnabled={featureLimits?.imageGenerationEnabled ?? true}
						videoEnabled={featureLimits?.videoGenerationEnabled ?? true}
						onToggle={(mode) => void toggleMode(mode)}
					/>
				</div>

				<ModelPicker
					{models}
					{chatMode}
					selectedModelId={selectedModelForMode}
					onPick={(modelId) => void pickModel(modelId)}
				/>

				<!-- Advanced generation settings: md+ only (rarely tuned on mobile). -->
				<div class="max-md:hidden">
					<GenerationConfig
						{chatMode}
						imageSettingsRaw={conversation?.imageGenerationSettings ?? null}
						videoSettingsRaw={conversation?.videoGenerationSettings ?? null}
						onImageChange={(settings) => void applyImageSettings(settings)}
						onVideoChange={(settings) => void applyVideoSettings(settings)}
					/>
				</div>

				<input
					bind:this={fileInput}
					type="file"
					multiple
					class="hidden"
					onchange={(event) => {
						const files = event.currentTarget.files;
						if (files && files.length > 0) void attach(files);
						event.currentTarget.value = '';
					}}
				/>

				<div class="flex-1"></div>

				<ContextIndicator
					{store}
					{isOwner}
					selectedContextWindow={selectedModel?.contextWindow ?? null}
					isAuto={selectedModelForMode === null}
				/>

				{#if store.agentThinking}
					<!-- Agent is responding: the send button becomes Stop, cancelling
					     the in-flight turn (classic stop_response / lucide-square). -->
					<button
						type="button"
						onclick={() => store.cancelResponse()}
						data-testid="composer-stop"
						aria-label="Stop response"
						title="Stop response"
						class="inline-flex size-9 max-md:size-10 shrink-0 items-center justify-center rounded-full bg-primary text-primary-foreground transition-opacity"
					>
						<Square class="size-3.5 fill-current" />
					</button>
				{:else}
					<button
						type="button"
						onclick={() => void submit()}
						disabled={!canSend}
						data-testid="composer-send"
						aria-label="Send message"
						title={store.connection === 'connecting' ? 'Connecting…' : undefined}
						class="inline-flex size-9 max-md:size-10 shrink-0 items-center justify-center rounded-full bg-primary text-primary-foreground transition-opacity disabled:opacity-40"
					>
						{#if store.sending || store.loading || store.connection === 'connecting'}
							<!-- Doubles as the quiet "connecting/loading" hint — the join
							     handshake shows here instead of a banner over the messages. -->
							<span
								class="size-3.5 animate-spin rounded-full border-2 border-current border-t-transparent"
							></span>
						{:else}
							<ArrowRight class="size-4" />
						{/if}
					</button>
				{/if}
			</div>
		</div>
	</div>
</div>

<PromptPickerDialog bind:open={promptPickerOpen} onInsert={insertPromptContent} />
