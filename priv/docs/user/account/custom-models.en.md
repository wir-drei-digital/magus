---
title: Your Own Models
description: Connect your own AI provider account and use custom models
order: 3
---

# Your Own Models

Besides the built-in model catalog, you can connect your own AI provider account and add models that run on your key. Useful when you have your own API subscription, need a model that is not in the catalog, or want usage billed directly to your provider account.

## Adding a provider

1. Go to **Settings** > **Providers** and add a provider.
2. Pick the provider type, give it a name, and paste your API key. Some types also take a base URL (for OpenAI-compatible endpoints).
3. Magus validates the key with a live check before saving.

Your key is encrypted, never shown again after saving, and only ever used for your own requests.

## Adding models

Open your provider and add a model. Where the provider's API supports it, Magus lists the available model ids for you to pick from; otherwise enter the model id manually.

You can also start from the catalog: pick **Use as template** on a catalog model to prefill the form (name, model id, context window, costs) and attach it to your provider.

## Using your models

Your models appear in the model picker alongside the catalog, marked as yours. Only you can select them. Usage runs on your key and is billed by your provider; it does not count against your Magus spend cap.

## If a model stops working

If a model you explicitly selected can no longer be used (for example you deleted it), the conversation does not silently switch models. Instead you get a notice with a **Reset to default and retry** button, which clears the broken selection and re-sends your message with your default model.

## Limits

There is a cap on how many providers and models you can add. Deleting your account removes your providers, models, and keys.
