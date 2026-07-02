import { describe, it, expect } from 'vitest';
import { formatCents, formatTokens, formatCap } from './format';

describe('billing format helpers', () => {
	describe('formatCents', () => {
		it('formats cents as a CHF amount with two decimals', () => {
			expect(formatCents(0)).toBe('CHF 0.00');
			expect(formatCents(5000)).toBe('CHF 50.00');
			expect(formatCents(1234)).toBe('CHF 12.34');
		});

		it('renders a placeholder for a missing amount', () => {
			expect(formatCents(null)).toBe('—');
			expect(formatCents(undefined)).toBe('—');
		});
	});

	describe('formatTokens', () => {
		it('passes small counts through unchanged', () => {
			expect(formatTokens(0)).toBe('0');
			expect(formatTokens(999)).toBe('999');
		});

		it('abbreviates thousands with a K suffix', () => {
			expect(formatTokens(1000)).toBe('1.0K');
			expect(formatTokens(12_500)).toBe('12.5K');
		});

		it('abbreviates millions with an M suffix', () => {
			expect(formatTokens(1_000_000)).toBe('1.0M');
			expect(formatTokens(2_400_000)).toBe('2.4M');
		});
	});

	describe('formatCap', () => {
		it('formats a set cap as CHF', () => {
			expect(formatCap(5000)).toBe('CHF 50.00');
		});

		it('shows "No cap" when no cap is set', () => {
			expect(formatCap(null)).toBe('No cap');
		});
	});
});
