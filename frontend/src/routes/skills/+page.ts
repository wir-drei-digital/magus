import { redirect } from '@sveltejs/kit';
import { base } from '$app/paths';

export const load = () => {
	redirect(307, `${base}/library?type=skills`);
};
