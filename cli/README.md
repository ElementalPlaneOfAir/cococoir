# Cococoir CLI

A beautiful, interactive CLI for managing Cococoir homelab deployments.

## Installation

```bash
# Run directly from the flake
nix run github:your-username/cococoir

# Or install permanently
nix profile install github:your-username/cococoir
```

## Development

```bash
nix develop

cd cli
go run .
```

## Commands

### `cococoir init [directory]`

Create a new Cococoir project with an interactive wizard.

```bash
cococoir init my-homelab
```

This will guide you through:
- Setting your base domain
- Choosing a Hetzner server type and location
- Selecting services to enable
- Generating NixOS and Terraform configuration

### `cococoir add service`

Add a new service to your existing project.

```bash
cococoir add service
```

### `cococoir status`

Show the status of your Cococoir deployment.

```bash
cococoir status
```

### `cococoir version`

Print version information.

## Architecture

The CLI is built with:
- **Cobra** — Command structure and flag parsing
- **Huh** (Charm) — Interactive forms and prompts
- **Lipgloss** — Beautiful terminal styling
- **Bubble Tea** — For future TUI dashboards

## Future Ideas

- [ ] Parse existing `flake.nix` to show real service status
- [ ] SSH into servers to check systemd service health
- [ ] Generate service configs by reading NixOS options
- [ ] AI-assisted module creation (read NixOS docs, suggest configs)
- [ ] Interactive log viewer with `tail` functionality
- [ ] Certificate expiry monitoring
