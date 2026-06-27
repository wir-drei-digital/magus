/**
 * Emoji shortcode conversion for chat markdown, matching the workbench MDEx
 * `shortcodes: true` option (lib/magus_web/workbench/chat/components/message/helpers.ex).
 *
 * Implemented as a marked *inline* extension so `:name:` is converted in prose
 * but left literal inside code spans / fences (marked tokenizes code before
 * inline extensions run, so the inner text is never offered to this tokenizer).
 *
 * This is a curated common-shortcode map, NOT the full ~1800-entry GitHub set:
 * the light pipeline (markdown.ts) deliberately stays small and ships in the
 * main chat bundle, so a full emoji dataset would defeat its purpose. Unknown
 * shortcodes are left as literal text. Add entries below as needed.
 */
import type { MarkedExtension, TokenizerAndRendererExtension, Tokens } from 'marked';

/** GitHub-style `:shortcode:` → unicode. Shortcode charset matches GitHub: [a-z0-9_+-]. */
export const EMOJI_SHORTCODES: Record<string, string> = {
	// faces
	smile: '😄',
	smiley: '😃',
	grin: '😁',
	laughing: '😆',
	satisfied: '😆',
	joy: '😂',
	rofl: '🤣',
	sweat_smile: '😅',
	wink: '😉',
	blush: '😊',
	slightly_smiling_face: '🙂',
	upside_down_face: '🙃',
	heart_eyes: '😍',
	kissing_heart: '😘',
	thinking: '🤔',
	neutral_face: '😐',
	unamused: '😒',
	roll_eyes: '🙄',
	smirk: '😏',
	relieved: '😌',
	pensive: '😔',
	confused: '😕',
	cry: '😢',
	sob: '😭',
	disappointed: '😞',
	weary: '😩',
	triumph: '😤',
	rage: '😡',
	angry: '😠',
	sunglasses: '😎',
	nerd_face: '🤓',
	hugs: '🤗',
	scream: '😱',
	flushed: '😳',
	sleeping: '😴',
	sweat: '😓',
	grimacing: '😬',
	// hands / gestures
	'+1': '👍',
	thumbsup: '👍',
	'-1': '👎',
	thumbsdown: '👎',
	ok_hand: '👌',
	punch: '👊',
	fist: '✊',
	wave: '👋',
	raised_hands: '🙌',
	pray: '🙏',
	clap: '👏',
	muscle: '💪',
	point_up: '☝️',
	point_down: '👇',
	point_left: '👈',
	point_right: '👉',
	v: '✌️',
	handshake: '🤝',
	// hearts / symbols
	heart: '❤️',
	yellow_heart: '💛',
	green_heart: '💚',
	blue_heart: '💙',
	purple_heart: '💜',
	broken_heart: '💔',
	sparkling_heart: '💖',
	two_hearts: '💕',
	fire: '🔥',
	star: '⭐',
	star2: '🌟',
	sparkles: '✨',
	zap: '⚡',
	boom: '💥',
	collision: '💥',
	tada: '🎉',
	confetti_ball: '🎊',
	rocket: '🚀',
	'100': '💯',
	heavy_check_mark: '✔️',
	white_check_mark: '✅',
	x: '❌',
	warning: '⚠️',
	question: '❓',
	exclamation: '❗',
	bulb: '💡',
	eyes: '👀',
	bell: '🔔',
	lock: '🔒',
	key: '🔑',
	gear: '⚙️',
	wrench: '🔧',
	hammer: '🔨',
	bug: '🐛',
	package: '📦',
	memo: '📝',
	pencil: '📝',
	book: '📖',
	books: '📚',
	chart_with_upwards_trend: '📈',
	hourglass: '⌛',
	alarm_clock: '⏰',
	coffee: '☕',
	beer: '🍺',
	pizza: '🍕',
	cake: '🎂',
	gift: '🎁',
	trophy: '🏆',
	dart: '🎯',
	crown: '👑',
	gem: '💎',
	moneybag: '💰',
	bomb: '💣',
	skull: '💀',
	ghost: '👻',
	robot: '🤖',
	poop: '💩',
	hankey: '💩',
	sunny: '☀️',
	rainbow: '🌈',
	snowman: '⛄',
	// animals
	dog: '🐶',
	cat: '🐱',
	unicorn: '🦄',
	penguin: '🐧',
	snake: '🐍',
	whale: '🐳',
	octopus: '🐙',
	bee: '🐝',
	ladybug: '🐞',
	ship: '🚢'
};

const SHORTCODE_RE = /^:([a-z0-9_+-]+):/;

type EmojiToken = Tokens.Generic & { type: 'emojiShortcode'; emoji: string };

const emojiExtension: TokenizerAndRendererExtension = {
	name: 'emojiShortcode',
	level: 'inline',
	start(src: string) {
		const idx = src.indexOf(':');
		return idx < 0 ? undefined : idx;
	},
	tokenizer(src: string) {
		const match = SHORTCODE_RE.exec(src);
		if (!match) return undefined;
		const emoji = EMOJI_SHORTCODES[match[1]];
		if (!emoji) return undefined; // unknown shortcode → leave literal
		return { type: 'emojiShortcode', raw: match[0], emoji } satisfies EmojiToken;
	},
	renderer(token) {
		return (token as EmojiToken).emoji;
	}
};

/** marked extension: converts known `:shortcodes:` to unicode (inline level only). */
export const markedEmojiShortcodes: MarkedExtension = { extensions: [emojiExtension] };
