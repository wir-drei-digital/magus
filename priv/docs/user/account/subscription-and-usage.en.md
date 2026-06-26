---
title: Subscription & Usage
description: How the Free and Pay-as-you-go plans work, why there is a base fee, and how spending limits protect you
order: 2
---

# Subscription & Usage

Magus has exactly two plans: **Free** and **Pay-as-you-go**. There are no tiers, no token bundles, and no markup on AI usage. Pay-as-you-go is a small monthly base fee plus your actual AI usage, billed at cost.

## Where your money goes

```
Your monthly bill
│
├── Base fee ─────────────► the platform costs we pay to keep Magus running:
│                           database · hosting · file storage · search API ·
│                           other API providers · backups · maintenance
│
└── AI usage (at cost) ───► passed straight through to the AI providers —
                            no markup, you pay exactly what we pay
```

**Why a base fee?** Running Magus costs real money even before a single AI request: the database, hosting, file storage, and the external API providers we integrate (such as the search API) all have to be paid. The base fee exists to get the platform going and keep it running — **we don't earn money on it**. What you get is an online, hosted service that is managed by us — and that we use ourselves every day. The current base fee is always shown in **Account Settings → Subscription**, and it goes *down* for everyone as more people join, because the fixed costs are shared across more users.

## Plans

### Free

The free plan lets you try Magus at no cost. It includes a **small one-time trial allowance — enough for roughly 10 typical chat messages** — with access to standard models (up to the 2x cost tier). It costs us practically nothing and lets you test the full harness: real conversations, agents, and tools. Your trial usage is displayed in **Account Settings → Subscription** exactly like paid usage, so you always see how much is left. When the allowance is used up, AI responses pause until you subscribe to Pay-as-you-go.

Storage is limited on the free plan, and premium or high-cost models are not available. Spending controls are not needed (and not active) — you can't spend money on the free plan.

### Pay-as-you-go

The paid plan is one base fee plus usage at cost:

- **Base fee** — covers infrastructure and operations (see above). Available monthly or annually; the annual option includes one month free.
- **AI usage** — every request is billed at the real provider cost in CHF, with no markup. What a request actually cost is recorded transparently per request.
- **What's free** — background work (memory extraction, automatic conversation titles, embeddings) is not billed.

For a sense of scale: a typical chat turn costs around 1 Rappen. Light use stays under CHF 5/month; heavy agent use can reach CHF 20+.

These are the only two plans. Usage is controlled with spending limits, not prepaid message units.

## Spending limits

Because usage is billed at cost, you control how much you can spend. The controls live in **Account Settings → Subscription → Spending controls** (they require an active Pay-as-you-go subscription).

- **Monthly spend cap** — a hard limit on your AI usage per billing period. If you don't set one, a default cap of CHF 20 applies. When the cap is reached, AI responses pause until the next billing period or until you raise the cap — you can never be surprised by a bill.
- **Pick your own cap** — use the slider, a preset, or a custom amount.
- **Early warning** — once you've used most of your cap, the usage indicator warns you before anything stops.
- **No spend cap (optional)** — if you prefer never to be blocked, you can turn the cap off entirely. Your usage is then never paused, and whatever you use is billed with your monthly invoice. You pay exactly what you use.

If you have a wallet balance (for example from an annual-plan price adjustment), it is used up first before anything counts against your cap.

## Storage limits

Your plan determines how much file storage you have and the maximum size for individual uploads. You can see your current usage in **Account Settings** under **Storage**.

If you're running low on storage, you can:
- Delete files you no longer need (see [Files & Storage](../files/files-and-storage.en.md))
- Subscribe to Pay-as-you-go for higher storage limits

## Viewing your current usage

1. Go to **Account Settings**
2. Open the **Subscription** section

You'll see what you've spent this billing period in CHF, your cap, tokens used, and your wallet balance if you have one. The workbench sidebar shows the same numbers at a glance.

## Subscribing

1. Go to **Account Settings**
2. Open the **Subscription** section
3. Choose **Subscribe monthly** or **Subscribe annually**
4. Complete the Stripe checkout

Your subscription is active immediately. You'll receive a confirmation email from Stripe.

## Managing payment via Stripe

Magus uses Stripe to handle payments securely. Your card details are stored by Stripe, not by Magus.

To manage your payment method or billing information:

1. Go to **Account Settings**
2. Open the **Subscription** section
3. Click **Manage subscription**

This opens the Stripe customer portal, where you can update your payment method, download invoices, view your billing history, or change your billing cycle.

## Canceling

Cancel anytime via **Manage subscription** in the Stripe portal. Your plan remains active until the end of the current billing period; outstanding usage is billed with the final invoice. After that, your account reverts to the free plan. Your data (conversations, agents, prompts) is retained — you won't lose anything, but free plan limits apply again.

## Usage overrides

In some cases, Magus may grant extra allowances as part of a promotion or support arrangement. These overrides are shown in your Subscription section if active and may have an expiration date.
