package cmd

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/charmbracelet/huh"
	"github.com/charmbracelet/lipgloss"
	"github.com/spf13/cobra"
)

var initCmd = &cobra.Command{
	Use:   "init [directory]",
	Short: "Create a new Cococoir project",
	Long:  "Scaffold a new Cococoir deployment repository with NixOS configuration, Terraform infrastructure, and service templates.",
	Args:  cobra.MaximumNArgs(1),
	RunE:  runInit,
}

func runInit(cmd *cobra.Command, args []string) error {
	var projectDir string
	if len(args) > 0 {
		projectDir = args[0]
	} else {
		projectDir = "my-homelab"
	}

	// Check if directory exists
	if _, err := os.Stat(projectDir); err == nil {
		return fmt.Errorf("directory %q already exists", projectDir)
	}

	titleStyle := lipgloss.NewStyle().
		Foreground(lipgloss.Color("#cba6f7")).
		Bold(true).
		MarginBottom(1)

	fmt.Println(titleStyle.Render("✨ Creating a new Cococoir project"))

	// Collect configuration via interactive form
	var (
		domain          string
		serverType      string
		location        string
		sshKey          string
		enableTerraform bool
		enableServices  []string
	)

	form := huh.NewForm(
		huh.NewGroup(
			huh.NewInput().
				Title("What is your base domain?").
				Placeholder("example.com").
				Value(&domain).
				Validate(func(s string) error {
					if s == "" {
						return fmt.Errorf("domain is required")
					}
					return nil
				}),

			huh.NewSelect[string]().
				Title("Hetzner server type").
				Options(
					huh.NewOption("CX22 — 2 vCPU, 4 GB RAM (~€4.51/mo)", "cx22"),
					huh.NewOption("CPX11 — 2 vCPU, 2 GB RAM (~€4.51/mo)", "cpx11"),
					huh.NewOption("CPX21 — 4 vCPU, 8 GB RAM (~€8.91/mo)", "cpx21"),
				).
				Value(&serverType),

			huh.NewSelect[string]().
				Title("Hetzner datacenter location").
				Options(
					huh.NewOption("Nuremberg (nbg1)", "nbg1"),
					huh.NewOption("Falkenstein (fsn1)", "fsn1"),
					huh.NewOption("Helsinki (hel1)", "hel1"),
					huh.NewOption("Ashburn, VA (ash)", "ash"),
				).
				Value(&location),

			huh.NewInput().
				Title("SSH public key path").
				Placeholder("~/.ssh/id_ed25519.pub").
				Value(&sshKey).
				Validate(func(s string) error {
					if s == "" {
						return fmt.Errorf("SSH key path is required")
					}
					path := expandPath(s)
					if _, err := os.Stat(path); err != nil {
						return fmt.Errorf("SSH key not found at %s", path)
					}
					return nil
				}),

			huh.NewConfirm().
				Title("Include Terraform infrastructure configuration?").
				Description("Creates Hetzner Cloud + DNS setup for your VPS.").
				Value(&enableTerraform).
				Affirmative("Yes").
				Negative("No"),

			huh.NewMultiSelect[string]().
				Title("Which services would you like to enable?").
				Options(
					huh.NewOption("Jellyfin (media server)", "jellyfin"),
					huh.NewOption("Vaultwarden (password manager)", "vaultwarden"),
					huh.NewOption("Forgejo (Git forge)", "forgejo"),
					huh.NewOption("Matrix (chat server)", "matrix"),
					huh.NewOption("CryptPad (collaborative docs)", "cryptpad"),
					huh.NewOption("Media Stack (Radarr, Sonarr, etc.)", "media-stack"),
					huh.NewOption("Kavita (ebook reader)", "kavita"),
				).
				Value(&enableServices),
		),
	)

	if err := form.Run(); err != nil {
		return fmt.Errorf("form cancelled: %w", err)
	}

	// Create project structure
	fmt.Println()
	fmt.Println(lipgloss.NewStyle().
		Foreground(lipgloss.Color("#a6e3a1")).
		Render("📁 Creating project structure..."))

	if err := os.MkdirAll(projectDir, 0755); err != nil {
		return fmt.Errorf("creating project directory: %w", err)
	}

	// Create directories
	dirs := []string{
		"hosts",
		"modules",
		"secrets",
	}
	if enableTerraform {
		dirs = append(dirs, "terraform")
	}

	for _, dir := range dirs {
		if err := os.MkdirAll(filepath.Join(projectDir, dir), 0755); err != nil {
			return fmt.Errorf("creating directory %s: %w", dir, err)
		}
	}

	// Write flake.nix
	flakeContent := generateFlake(domain, enableServices)
	if err := os.WriteFile(filepath.Join(projectDir, "flake.nix"), []byte(flakeContent), 0644); err != nil {
		return fmt.Errorf("writing flake.nix: %w", err)
	}

	// Write host configuration
	hostConfig := generateHostConfig(domain, enableServices)
	if err := os.WriteFile(filepath.Join(projectDir, "hosts", "homelab.nix"), []byte(hostConfig), 0644); err != nil {
		return fmt.Errorf("writing host config: %w", err)
	}

	// Write Terraform config if enabled
	if enableTerraform {
		tfContent := generateTerraformConfig(domain, serverType, location, sshKey)
		if err := os.WriteFile(filepath.Join(projectDir, "terraform", "main.tf"), []byte(tfContent), 0644); err != nil {
			return fmt.Errorf("writing terraform config: %w", err)
		}

		tfVarsContent := generateTerraformVars(domain, sshKey)
		if err := os.WriteFile(filepath.Join(projectDir, "terraform", "terraform.tfvars.example"), []byte(tfVarsContent), 0644); err != nil {
			return fmt.Errorf("writing terraform.tfvars.example: %w", err)
		}
	}

	// Write README
	readmeContent := generateReadme(projectDir, domain, enableTerraform, enableServices)
	if err := os.WriteFile(filepath.Join(projectDir, "README.md"), []byte(readmeContent), 0644); err != nil {
		return fmt.Errorf("writing README.md: %w", err)
	}

	// Success message
	fmt.Println()
	successStyle := lipgloss.NewStyle().
		Foreground(lipgloss.Color("#a6e3a1")).
		Bold(true).
		MarginBottom(1)

	fmt.Println(successStyle.Render("✅ Project created successfully!"))

	fmt.Println(lipgloss.NewStyle().
		Foreground(lipgloss.Color("#cdd6f4")).
		Render(fmt.Sprintf("📂 Location: %s", projectDir)))

	fmt.Println()
	fmt.Println(lipgloss.NewStyle().
		Foreground(lipgloss.Color("#f9e2af")).
		Bold(true).
		Render("Next steps:"))

	steps := []string{
		fmt.Sprintf("cd %s", projectDir),
	}

	if enableTerraform {
		steps = append(steps,
			"cp terraform/terraform.tfvars.example terraform/terraform.tfvars",
			"# Edit terraform/terraform.tfvars with your API tokens",
			"nix develop",
			"cd terraform && terraform init && terraform apply",
		)
	}

	steps = append(steps,
		"# Review and edit hosts/homelab.nix",
		"# Deploy with: nixos-rebuild switch --flake .#homelab --target-host root@<your-server-ip>",
	)

	for i, step := range steps {
		num := lipgloss.NewStyle().
			Foreground(lipgloss.Color("#89b4fa")).
			Bold(true).
			Render(fmt.Sprintf("%d.", i+1))
		fmt.Printf("  %s %s\n", num, step)
	}

	return nil
}

func expandPath(path string) string {
	if strings.HasPrefix(path, "~/") {
		home, _ := os.UserHomeDir()
		return filepath.Join(home, path[2:])
	}
	return path
}

func generateFlake(domain string, services []string) string {
	var serviceImports strings.Builder
	for _, svc := range services {
		serviceImports.WriteString(fmt.Sprintf("        cococoir.services.%s.enable = true;\n", svc))
	}

	return fmt.Sprintf(`{
  description = "%s - Cococoir homelab";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    cococoir.url = "github:your-username/cococoir"; # TODO: Update to your fork
  };

  outputs = { self, nixpkgs, cococoir, ... }@inputs: {
    nixosConfigurations.homelab = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inherit inputs; };
      modules = [
        cococoir.nixosModules.default
        ./hosts/homelab.nix
      ];
    };
  };
}
`, domain)
}

func generateHostConfig(domain string, services []string) string {
	var serviceConfig strings.Builder
	for _, svc := range services {
		switch svc {
		case "jellyfin":
			serviceConfig.WriteString(fmt.Sprintf(`
    cococoir.services.jellyfin = {
      enable = true;
      domain = "jellyfin.%s";
      public = true;
    };
`, domain))
		case "vaultwarden":
			serviceConfig.WriteString(fmt.Sprintf(`
    cococoir.services.vaultwarden = {
      enable = true;
      domain = "vault.%s";
      public = true;
      signupsAllowed = false;
    };
`, domain))
		case "forgejo":
			serviceConfig.WriteString(fmt.Sprintf(`
    cococoir.services.forgejo = {
      enable = true;
      domain = "git.%s";
      public = true;
    };
`, domain))
		case "matrix":
			serviceConfig.WriteString(fmt.Sprintf(`
    cococoir.services.matrix = {
      enable = true;
      domain = "matrix.%s";
      public = true;
    };
`, domain))
		case "cryptpad":
			serviceConfig.WriteString(fmt.Sprintf(`
    cococoir.services.cryptpad = {
      enable = true;
      domain = "pad.%s";
      public = true;
    };
`, domain))
		case "media-stack":
			serviceConfig.WriteString(fmt.Sprintf(`
    cococoir.services.media-stack = {
      enable = true;
      domain = "media.%s";
      public = true;
    };
`, domain))
		case "kavita":
			serviceConfig.WriteString(fmt.Sprintf(`
    cococoir.services.kavita = {
      enable = true;
      domain = "books.%s";
      public = true;
    };
`, domain))
		}
	}

	return fmt.Sprintf(`{ config, pkgs, ... }:
{
  # Import your hardware configuration
  # imports = [ ./hardware-configuration.nix ];

  networking.hostName = "homelab";

  cococoir = {
    domain = "%s";
    
    adminUsers.your-username = {
      keys = [ 
        # TODO: Add your SSH public key here
      ];
    };
  };

  # VPN tunnel to VPS
  cococoir.proxy.client = {
    enable = true;
    serverAddress = "YOUR_VPS_IP"; # TODO: Update after terraform apply
    credentialsFile = config.sops.secrets.rathole-client.path;
  };
%s
  # This value determines the NixOS release with which your system is compatible.
  system.stateVersion = "24.11";
}
`, domain, serviceConfig.String())
}

func generateTerraformConfig(domain, serverType, location, sshKey string) string {
	return fmt.Sprintf(`terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = ">= 1.45.0"
    }
    hetznerdns = {
      source  = "germanbrew/hetznerdns"
      version = ">= 3.1.0"
    }
  }
}

provider "hcloud" {
  # Set HCLOUD_TOKEN environment variable
}

provider "hetznerdns" {
  # Set HETZNER_DNS_API_TOKEN environment variable
}

module "vps" {
  source = "github.com/your-username/cococoir//terraform/modules/vps" # TODO: Update to your fork

  name           = "cococoir-proxy"
  server_type    = "%s"
  location       = "%s"
  ssh_public_key = file("%s")
}

module "dns" {
  source = "github.com/your-username/cococoir//terraform/modules/dns" # TODO: Update to your fork

  zone_name = "%s"
  records = [
    {
      name  = "@"
      type  = "A"
      value = module.vps.ipv4_address
      ttl   = 300
    },
    {
      name  = "*"
      type  = "A"
      value = module.vps.ipv4_address
      ttl   = 300
    },
    {
      name  = "@"
      type  = "AAAA"
      value = module.vps.ipv6_address
      ttl   = 300
    },
    {
      name  = "*"
      type  = "AAAA"
      value = module.vps.ipv6_address
      ttl   = 300
    },
  ]
}

output "server_ip" {
  value = module.vps.ipv4_address
}

output "nameservers" {
  value = module.dns.nameservers
}
`, serverType, location, sshKey, domain)
}

func generateTerraformVars(domain, sshKey string) string {
	return fmt.Sprintf(`# Copy this file to terraform.tfvars and fill in your values

# Your Hetzner Cloud API token
# hcloud_token = "your-token-here"

# Your Hetzner DNS API token  
# hetznerdns_token = "your-token-here"
`)
}

func generateReadme(projectDir, domain string, terraform bool, services []string) string {
	var svcList strings.Builder
	for _, svc := range services {
		svcList.WriteString(fmt.Sprintf("- %s\n", svc))
	}

	var tfSection string
	if terraform {
		tfSection = `
## Infrastructure

Terraform configuration is included to provision a Hetzner Cloud VPS and DNS records.

1. Copy terraform/terraform.tfvars.example to terraform/terraform.tfvars
2. Add your Hetzner API tokens
3. Run: cd terraform && terraform init && terraform apply
`
	}

	return fmt.Sprintf(`# %s

Cococoir homelab deployment for %s.

## Services

%s
%s
## Deployment

1. Update hosts/homelab.nix with your SSH key and VPS IP
2. Run: nixos-rebuild switch --flake .#homelab --target-host root@<your-vps-ip>

## Management

Use the Cococoir CLI to add services or check status:

    cococoir add service    # Add a new service
    cococoir status         # Check service status
`, filepath.Base(projectDir), domain, svcList.String(), tfSection)
}
