<script lang="ts">
	import { Film, Image } from '@lucide/svelte';
	import type { ChatMode } from '$lib/ash/api';

	// Shared image/video generation toggles. onToggle receives the tapped mode;
	// the caller decides whether that flips chat_mode locally (LandingComposer)
	// or persists it to the conversation (Composer). The *Enabled flags gate the
	// toggles by plan (the backend still enforces); default true until loaded.
	let {
		chatMode,
		onToggle,
		imageEnabled = true,
		videoEnabled = true
	}: {
		chatMode: ChatMode;
		onToggle: (mode: ChatMode) => void;
		imageEnabled?: boolean;
		videoEnabled?: boolean;
	} = $props();
</script>

<button
	type="button"
	disabled={!imageEnabled}
	class="inline-flex size-8 items-center justify-center rounded-lg transition-colors {chatMode ===
	'image_generation'
		? 'bg-accent text-accent-foreground'
		: 'text-muted-foreground hover:bg-accent/60 hover:text-foreground'} {imageEnabled
		? ''
		: 'cursor-not-allowed opacity-40 hover:bg-transparent'}"
	title={imageEnabled ? 'Image generation' : 'Image generation requires an upgraded plan'}
	aria-label={imageEnabled ? 'Image generation' : 'Image generation requires an upgraded plan'}
	aria-pressed={chatMode === 'image_generation'}
	data-testid="mode-toggle-image"
	onclick={() => onToggle('image_generation')}
>
	<Image class="size-4" />
</button>

<button
	type="button"
	disabled={!videoEnabled}
	class="inline-flex size-8 items-center justify-center rounded-lg transition-colors {chatMode ===
	'video_generation'
		? 'bg-accent text-accent-foreground'
		: 'text-muted-foreground hover:bg-accent/60 hover:text-foreground'} {videoEnabled
		? ''
		: 'cursor-not-allowed opacity-40 hover:bg-transparent'}"
	title={videoEnabled ? 'Video generation' : 'Video generation requires an upgraded plan'}
	aria-label={videoEnabled ? 'Video generation' : 'Video generation requires an upgraded plan'}
	aria-pressed={chatMode === 'video_generation'}
	data-testid="mode-toggle-video"
	onclick={() => onToggle('video_generation')}
>
	<Film class="size-4" />
</button>
