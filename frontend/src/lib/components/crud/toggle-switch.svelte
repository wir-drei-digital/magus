<script lang="ts">
	// Accessible on/off switch (`role="switch"` + `aria-checked`). The standard
	// control for booleans across CRUD views — use this instead of a raw checkbox.
	let {
		checked = false,
		disabled = false,
		onchange,
		label,
		testid
	}: {
		checked?: boolean;
		disabled?: boolean;
		onchange: (next: boolean) => void;
		label?: string;
		testid?: string;
	} = $props();
</script>

<button
	type="button"
	role="switch"
	aria-checked={checked}
	aria-label={label}
	{disabled}
	data-testid={testid}
	onclick={() => onchange(!checked)}
	class="relative inline-flex h-5 w-9 shrink-0 cursor-pointer items-center rounded-full transition-colors disabled:cursor-not-allowed disabled:opacity-50 {checked
		? 'bg-primary'
		: 'bg-input'}"
>
	<span
		class="inline-block size-4 transform rounded-full bg-background shadow transition-transform {checked
			? 'translate-x-4'
			: 'translate-x-0.5'}"
	></span>
</button>
