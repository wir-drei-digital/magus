<script lang="ts">
	import { resendConfirmation } from '$lib/ash/api';
	import { session } from '$lib/stores/session.svelte';

	// Minimal top banner: shown whenever the signed-in user hasn't clicked
	// their confirmation link yet. The resend button disables itself once a
	// send succeeds — no retry loop, no dismiss (it reappears every load
	// until the user actually confirms).
	let sending = $state(false);
	let sent = $state(false);

	async function resend() {
		if (!session.user || sending || sent) return;
		sending = true;
		const result = await resendConfirmation(session.user.id);
		sending = false;
		if (result.success) sent = true;
	}
</script>

{#if session.user && !session.user.emailConfirmed}
	<div
		class="border-b bg-warning/10 px-4 py-1.5 text-center text-xs text-warning"
		role="status"
		data-testid="email-confirmation-banner"
	>
		Confirm your email to start chatting. Check your inbox for the confirmation link.
		<button
			type="button"
			class="ml-2 font-medium underline hover:no-underline disabled:no-underline disabled:opacity-60"
			disabled={sending || sent}
			onclick={() => void resend()}
			data-testid="email-confirmation-resend"
		>
			{#if sent}
				Email sent
			{:else if sending}
				Sending…
			{:else}
				Resend email
			{/if}
		</button>
	</div>
{/if}
