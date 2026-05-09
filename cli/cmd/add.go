package cmd

import (
	"fmt"

	"github.com/charmbracelet/huh"
	"github.com/charmbracelet/lipgloss"
	"github.com/spf13/cobra"
)

var addCmd = &cobra.Command{
	Use:   "add [resource]",
	Short: "Add a new resource to your Cococoir project",
	Long:  "Add services, users, or other resources to your existing Cococoir deployment.",
}

func init() {
	addCmd.AddCommand(addServiceCmd)
}

var addServiceCmd = &cobra.Command{
	Use:   "service",
	Short: "Add a new service to your project",
	RunE: func(cmd *cobra.Command, args []string) error {
		var (
			serviceName string
			domain      string
			public      bool
		)

		titleStyle := lipgloss.NewStyle().
			Foreground(lipgloss.Color("#cba6f7")).
			Bold(true).
			MarginBottom(1)

		fmt.Println(titleStyle.Render("➕ Add a new service"))

		form := huh.NewForm(
			huh.NewGroup(
				huh.NewSelect[string]().
					Title("Which service would you like to add?").
					Options(
						huh.NewOption("Jellyfin (media server)", "jellyfin"),
						huh.NewOption("Vaultwarden (password manager)", "vaultwarden"),
						huh.NewOption("Forgejo (Git forge)", "forgejo"),
						huh.NewOption("Matrix (chat server)", "matrix"),
						huh.NewOption("CryptPad (collaborative docs)", "cryptpad"),
						huh.NewOption("Media Stack (Radarr, Sonarr, etc.)", "media-stack"),
						huh.NewOption("Kavita (ebook reader)", "kavita"),
						huh.NewOption("Custom service", "custom"),
					).
					Value(&serviceName),

				huh.NewInput().
					Title("Domain for this service").
					Placeholder("service.example.com").
					Value(&domain),

				huh.NewConfirm().
					Title("Make this service publicly accessible?").
					Value(&public).
					Affirmative("Yes").
					Negative("No"),
			),
		)

		if err := form.Run(); err != nil {
			return fmt.Errorf("form cancelled: %w", err)
		}

		fmt.Println()
		fmt.Println(lipgloss.NewStyle().
			Foreground(lipgloss.Color("#a6e3a1")).
			Render(fmt.Sprintf("✅ Configuration for %s generated!", serviceName)))

		fmt.Println()
		fmt.Println(lipgloss.NewStyle().
			Foreground(lipgloss.Color("#cdd6f4")).
			Render("Add the following to your NixOS configuration:"))
		fmt.Println()

		config := fmt.Sprintf(`  cococoir.services.%s = {
    enable = true;
    domain = "%s";
    public = %t;
  };`, serviceName, domain, public)

		fmt.Println(lipgloss.NewStyle().
			Foreground(lipgloss.Color("#89dceb")).
			Render(config))

		fmt.Println()
		fmt.Println(lipgloss.NewStyle().
			Foreground(lipgloss.Color("#f9e2af")).
			Render("Then rebuild your system with: nixos-rebuild switch --flake .#homelab"))

		return nil
	},
}
