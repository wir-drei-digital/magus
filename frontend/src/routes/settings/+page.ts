import { redirect } from '@sveltejs/kit';
import { base } from '$app/paths';

export function load(): never {
	redirect(307, `${base}/settings/profile`);
}
