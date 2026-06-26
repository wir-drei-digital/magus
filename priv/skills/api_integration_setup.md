---
name: api_integration_setup
description: Set up custom API integrations by reading documentation, OpenAPI specs, or user descriptions
tags:
  - integrations
  - api
  - setup
tools:
  - configure_api_integration
---

# API Integration Setup

You are setting up a custom API integration for the user. Follow these steps:

## Step 1: Understand the Request

Ask the user:
- What API do they want to connect?
- What operations do they need? (e.g., create issues, list items, send messages)
- Do they have documentation or an OpenAPI spec URL?

## Step 2: Gather API Information

Use one of these approaches based on what the user provides:

**If they provide a documentation URL:**
1. Use `web_fetch` to load the documentation page
2. Extract: base URL, authentication method, available endpoints, request/response formats
3. If the page is a heavy SPA that doesn't render well, ask the user to paste the relevant section

**If they provide an OpenAPI/Swagger spec URL:**
1. Use `web_fetch` to load the spec (JSON or YAML)
2. Parse the spec to extract: servers (base URL), securitySchemes (auth method), paths (endpoints)
3. For each relevant endpoint: extract method, path, parameters, request body schema, response schema

**If they describe the API verbally:**
1. Build the configuration from their description
2. Ask clarifying questions about endpoints, methods, and expected request/response formats

**If no documentation is available, try API discovery:**
1. Try well-known OpenAPI spec paths: `/openapi.json`, `/swagger.json`, `/api-docs`, `/v2/api-docs`, `/.well-known/openapi.json`
2. Try OPTIONS on the base URL for allowed methods
3. Try GET on likely endpoints to inspect response shapes
4. Use error responses (400/422) to understand required fields

## Step 3: Build the Integration

Once you understand the API, call `configure_api_integration` with:
- `custom_agent_id`: The current agent's ID (from your context)
- `name`: A clear name for the API service
- `base_url`: The base URL for all API calls
- `auth_method`: One of "bearer", "api_key_header", "basic", or "none"
- `auth_header_name`: Only needed if auth_method is "api_key_header"
- `default_headers`: Headers that apply to all requests (e.g., Content-Type, API version headers)
- `endpoints`: Array of endpoint documentation objects, each with:
  - `key`: A slug identifier (e.g., "create_issue")
  - `name`: Human-readable name
  - `description`: What it does and when to use it (BE DETAILED — this is what you'll read later)
  - `method`: HTTP method
  - `path`: URL path (use {{placeholder}} for path parameters)
  - `body_template`: Example JSON body (optional but very helpful for POST/PUT/PATCH)
  - `response_description`: What the response contains (optional)
  - `example_response`: Example JSON response (optional)

## Step 4: Test (if possible)

After configuring, if the auth_method is "none" or the user confirms credentials are already configured:
1. Use `http_request` with the returned integration_id on a safe read-only endpoint (GET)
2. If the test fails, diagnose the issue:
   - Wrong base URL? Fix and reconfigure
   - Missing required header? Add to default_headers
   - Incorrect path? Update the endpoint
3. Call `configure_api_integration` again with corrections

## Step 5: Complete Setup

Once the integration is configured (and optionally tested), wrap up by:

1. Summarize what was set up: API name, base URL, number of endpoints, auth method
2. If auth_method is not "none", remind the user to add credentials
3. Provide an action card to navigate back to the agent's integrations page so they can add credentials:

```action_cards
{"layout":"list","cards":[{"title":"Go to Agent Settings","description":"Add your API credentials to activate the integration","action":{"type":"navigate","payload":"/agents/{agent_id}/edit/integrations"}}]}
```

Replace `{agent_id}` with the actual agent ID from the `custom_agent_id` parameter.

## Hard Rules

**CRITICAL — NEVER VIOLATE THESE:**
- **NEVER ask the user for API tokens, keys, passwords, or any credentials**
- **NEVER accept credentials even if the user volunteers them in chat**
- If the user tries to share a token, immediately say: "For security, please add your credentials in the agent settings page instead of sharing them in chat."
- If a test returns 401 or 403: "The integration is configured but needs credentials. Please go to your agent settings, find the [API Name] integration, and add your [Bearer Token / API Key / Username & Password] there."
- Always direct users to the agent settings page for credential entry
