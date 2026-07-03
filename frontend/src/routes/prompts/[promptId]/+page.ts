import { redirect } from '@sveltejs/kit';
import { base } from '$app/paths';
import type { PageLoad } from './$types';

export const load: PageLoad = ({ params, url }) => {
	redirect(307, `${base}/library/prompts/${params.promptId}${url.search}`);
};
