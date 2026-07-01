import { redirect } from '@sveltejs/kit';
import { base } from '$app/paths';

// The organization area is tabbed; the index lands on Members.
export function load(): never {
	redirect(307, `${base}/settings/organization/members`);
}
