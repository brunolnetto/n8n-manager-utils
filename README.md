# n8n Local Multi-Tenant Deployment Manager

An advanced shell script to deploy and manage multiple, isolated n8n instances that all run on a shared, resource-efficient backend infrastructure (Postgres and Redis).

This tool is designed for developers and teams who need to run several n8n environments locally without the overhead of duplicating the database and caching services for each one.

## Architecture

This tool uses a two-tiered approach:

1.  **Shared Infrastructure**: A single `docker-compose.shared.yml` manages one persistent Postgres and one Redis container. This is the foundation for all n8n instances and is managed with the `./deploy.sh shared` command.
2.  **n8n Instances**: Each n8n instance (composed of `editor`, `webhook`, and `worker` services) is defined in a `docker-compose.n8n.yml` template. The `./deploy.sh instance` command dynamically provisions a unique database and user on the shared Postgres for each instance, ensuring complete data isolation.

## Features

- **Multi-Tenancy**: Run dozens of n8n instances on a single shared backend, saving significant system resources.
- **Dynamic Provisioning**: Automatically creates and destroys unique databases and users for each instance.
- **Git-Ops Workflow**: Use a Git repository as the single source of truth for an instance's workflows and credentials.
- **Full Lifecycle Management**: Commands to manage both the shared infrastructure (`shared`) and the individual n8n instances (`instance`).
- **Stateful & Secure**: Persists unique, randomly generated secrets for each instance in local state files.

## Prerequisites

- `docker`
- `docker-compose`
- `git`
- `nc` (netcat)
- `psql` (Postgres client tools)

## Usage

### Step 1: Start the Shared Infrastructure
You only need to do this once. This will ask you to create a master password for the Postgres service.

```bash
./deploy.sh shared up
```

### Step 2: Manage n8n Instances

#### `instance up`
Deploys a new n8n instance. It will provision a new database, find an open port, and import workflows/credentials from your Git repository.

```bash
./deploy.sh instance up -s my-server -i production -r github.com/user/repo.git
```

#### `instance backup`
Exports the live workflows and credentials from a running instance and pushes them as a commit to your Git repository.

```bash
./deploy.sh instance backup -s my-server -i production -r github.com/user/repo.git
```

#### `instance down`
Stops and **completely removes** an n8n instance. This includes deleting its Docker containers, volumes, and de-provisioning its database and user from the shared Postgres service.

```bash
./deploy.sh instance down -s my-server -i production
```

#### `instance logs`
Follows the real-time logs for a specific n8n instance.

```bash
./deploy.sh instance logs -s my-server -i production
```

#### `instance status`
Lists all *running* n8n instances by inspecting active Docker containers.

```bash
./deploy.sh instance status
```

#### `instance list`
Lists all *known* n8n instances by reading their state files, regardless of whether they are running.

```bash
./deploy.sh instance list
```

#### `instance update`
Pulls the latest `n8nio/n8n` Docker image and restarts the specified instance with the new version.

```bash
./deploy.sh instance update -s my-server -i production
```

#### `instance prune`
Scans for and interactively offers to delete any orphaned Docker volumes that are not associated with a known instance state file.

```bash
./deploy.sh instance prune
```

### Options

| Flag | Description                                                    | Required For |
|------|----------------------------------------------------------------|--------------|
| `-s` | The server/environment name.                                   | `instance`   |
| `-i` | The specific instance name.                                    | `instance`   |
| `-r` | The Git repository URL (e.g., `github.com/user/repo.git`).      | `up`, `backup`|
| `-t` | The Git personal access token. If omitted, you will be prompted.| `up`, `backup`|
| `-p` | The starting port for the instance. Defaults to `5678`.        | `up` (opt)   |

---

### :warning: Important Security Note

The `backup` command exports credentials in a **decrypted, plain-text format** and **commits them to your Git repository**. This is necessary for portability. **Ensure your Git repository is private and handle access with extreme care.** 