import { describe, expect, it } from 'vitest';
import { eventSeverity, eventVisual } from './event-style';

describe('eventSeverity', () => {
	it('flags limit/storage events as warning', () => {
		expect(eventSeverity('You reached your daily limit')).toBe('warning');
		expect(eventSeverity('storage exceeded')).toBe('warning');
	});

	it('flags error/timeout/connection events as error', () => {
		expect(eventSeverity('The request failed')).toBe('error');
		expect(eventSeverity('Connection closed')).toBe('error');
		expect(eventSeverity('Request Timeout')).toBe('error');
	});

	it('defaults to info', () => {
		expect(eventSeverity('Searching the web')).toBe('info');
		expect(eventSeverity('')).toBe('info');
	});
});

describe('eventVisual', () => {
	it('maps severity to its matching icon', () => {
		expect(eventVisual('limit reached')).toEqual({ severity: 'warning', icon: 'warning' });
		expect(eventVisual('failed to run')).toEqual({ severity: 'error', icon: 'error' });
	});

	it('picks a content icon for info events', () => {
		expect(eventVisual('Search results')).toEqual({ severity: 'info', icon: 'search' });
		expect(eventVisual('Note saved')).toEqual({ severity: 'info', icon: 'note' });
		expect(eventVisual('Dice rolled')).toEqual({ severity: 'info', icon: 'dice' });
		expect(eventVisual('Something happened')).toEqual({ severity: 'info', icon: 'info' });
	});
});
