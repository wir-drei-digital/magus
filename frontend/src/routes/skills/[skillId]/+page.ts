import { redirect } from '@sveltejs/kit';
import { base } from '$app/paths';
import type { PageLoad } from './$types';

export const load: PageLoad = ({ params, url }) => {
	if (params.skillId === 'new') redirect(307, `${base}/library?new=skill`);
	redirect(307, `${base}/library/skills/${params.skillId}${url.search}`);
};
