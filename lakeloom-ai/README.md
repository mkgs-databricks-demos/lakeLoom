# lakeloom-ai

A Databricks App powered by [AppKit](https://databricks.github.io/appkit/), featuring React, TypeScript, and Tailwind CSS.

**Enabled plugins:**
- **Analytics** -- SQL query execution against Databricks SQL Warehouses
- **Lakebase** -- Fully managed Postgres database for transactional (OLTP) workloads on Databricks
- **Server** -- Express HTTP server with static file serving and Vite dev mode

## Prerequisites

- Node.js v22+ and npm
- Databricks CLI (for deployment)
- Access to a Databricks workspace

## Workspace IP Access Lists

Databricks Apps enforce workspace-level IP access lists. If your workspace has an
allow list configured, any client IP (including iOS devices calling the App) must
be in the allow list — otherwise the auth sidecar returns **403 Forbidden** even
when the Bearer token is valid.

### Check existing access lists

```
databricks ip-access-lists list
```

Example output:

```
ALLOW   ENABLED
f4dc1a12-f273-48a3-9732-70ed837b419e  lakeLoomZeroBus  98.10.37.0/24
```

### Create a new allow list

Replace the label, list_type, and ip_addresses with your values:

```
databricks ip-access-lists create --json '{"label": "lakeLoomZeroBus", "list_type": "ALLOW", "ip_addresses": ["98.10.37.0/24"]}'
```

### Edit an existing allow list

Use the list ID from the list command above:

```
databricks ip-access-lists update <LIST_ID> --json '{"label": "lakeLoomZeroBus", "list_type": "ALLOW", "ip_addresses": ["98.10.37.0/24"], "enabled": true}'
```

For our home network, the list ID is `f4dc1a12-f273-48a3-9732-70ed837b419e`
and the current CIDR is `98.10.37.0/24` (full /24 subnet).

### Common CIDR ranges for home networks

| CIDR | IPs | Use case |
| --- | --- | --- |
| /28 | 16 | Single static allocation |
| /24 | 256 | Full subnet (recommended for home ISPs) |
| /22 | 1024 | Covers ISP DHCP rotation across neighboring subnets |

> **Note:** Changes to IP access lists can take **up to 10 minutes** to propagate.
> During propagation, the App auth sidecar may transiently reject valid tokens
> with 403. If you see 403 errors immediately after an update, wait and retry.

### Diagnosing 403 from iOS

If the iPhone gets HTTP 403 on `/api/pairing/confirm` but the M2M token
acquisition succeeded (hits the workspace OIDC endpoint directly), the likely
cause is the App sidecar rejecting the request due to IP access list enforcement.

1. Check the phone's public IP: the iOS app logs it as `signin.public_ip`
2. Verify it falls within an enabled ALLOW list
3. Wait for propagation if the list was recently modified
4. Confirm with `databricks ip-access-lists list`

## Databricks Authentication

### Local Development

For local development, configure your environment variables by creating a `.env` file:

```
cp .env.example .env
```

Edit `.env` and set the environment variables you need:

```
DATABRICKS_HOST=https://your-workspace.cloud.databricks.com
DATABRICKS_APP_PORT=8000
# ... other environment variables, depending on the plugins you use
```

#### Lakebase Configuration

The Lakebase plugin requires additional environment variables for PostgreSQL connectivity. To learn how to configure the Lakebase plugin, see the [Lakebase plugin documentation](https://databricks.github.io/appkit/docs/plugins/lakebase).

### CLI Authentication

The Databricks CLI requires authentication to deploy and manage apps. Configure authentication using one of these methods:

#### OAuth U2M

Interactive browser-based authentication with short-lived tokens:

```
databricks auth login --host https://your-workspace.cloud.databricks.com
```

This will open your browser to complete authentication. The CLI saves credentials to `~/.databrickscfg`.

#### Configuration Profiles

Use multiple profiles for different workspaces:

```
[DEFAULT]
host = https://dev-workspace.cloud.databricks.com

[production]
host = https://prod-workspace.cloud.databricks.com
client_id = prod-client-id
client_secret = prod-client-secret
```

Deploy using a specific profile:

```
databricks bundle deploy --profile production
```

**Note:** Personal Access Tokens (PATs) are legacy authentication. OAuth is strongly recommended for better security.

## Getting Started

### Install Dependencies

```
npm install
```

### Development

Run the app in development mode with hot reload:

```
npm run dev
```

The app will be available at the URL shown in the console output.

### Build

Build both client and server for production:

```
npm run build
```

This creates:

- `dist/server.js` - Compiled server bundle
- `client/dist/` - Bundled client assets

### Production

Run the production build:

```
npm start
```

## Code Quality

There are a few commands to help you with code quality:

```
# Type checking
npm run typecheck

# Linting
npm run lint
npm run lint:fix

# Formatting
npm run format
npm run format:fix
```

## Deployment with Databricks Asset Bundles

### 1. Configure Bundle

Update `databricks.yml` with your workspace settings:

```
targets:
  default:
    workspace:
      host: https://your-workspace.cloud.databricks.com
```

Make sure to replace all placeholder values in `databricks.yml` with your actual resource IDs.

### 2. Validate Bundle

```
databricks bundle validate
```

### 3. Deploy

Deploy to the default target:

```
databricks bundle deploy
```

### 4. Run

Start the deployed app:

```
databricks bundle run <APP_NAME> -t dev
```

### Deploy to Production

1. Configure the production target in `databricks.yml`
2. Deploy to production:

```
databricks bundle deploy -t prod
```

## Project Structure

```
* client/          # React frontend
  * src/           # Source code
  * public/        # Static assets
* server/          # Express backend
  * server.ts      # Server entry point
  * routes/        # Routes
* shared/          # Shared types
* config/          # Configuration
  * queries/       # SQL query files
* databricks.yml   # Bundle configuration
* app.yaml         # App configuration
* .env.example     # Environment variables example
```

## Tech Stack

- **Backend**: Node.js, Express
- **Frontend**: React.js, TypeScript, Vite, Tailwind CSS, React Router
- **UI Components**: Radix UI, shadcn/ui
- **Databricks**: AppKit SDK
