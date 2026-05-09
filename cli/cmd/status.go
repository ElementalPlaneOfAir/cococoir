package cmd

import (
	"fmt"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/lipgloss/table"
	"github.com/spf13/cobra"
)

var statusCmd = &cobra.Command{
	Use:   "status",
	Short: "Show the status of your Cococoir deployment",
	Long:  "Display an overview of configured services, infrastructure state, and health.",
	RunE: func(cmd *cobra.Command, args []string) error {
		titleStyle := lipgloss.NewStyle().
			Foreground(lipgloss.Color("#cba6f7")).
			Bold(true).
			MarginBottom(1)

		fmt.Println(titleStyle.Render("📊 Cococoir Status"))

		// This is a placeholder implementation
		// In a real implementation, this would:
		// - Read the local flake.nix to detect configured services
		// - SSH into the server to check systemd service status
		// - Check if the VPS is reachable
		// - Show SSL certificate status

		headers := []string{"Service", "Domain", "Status", "Public"}
		rows := [][]string{
			{"jellyfin", "jellyfin.example.com", "✅ Running", "Yes"},
			{"vaultwarden", "vault.example.com", "✅ Running", "Yes"},
			{"caddy", "*.example.com", "✅ Running", "N/A"},
			{"rathole-client", "tunnel", "✅ Running", "N/A"},
		}

		t := table.New().
			Border(lipgloss.NormalBorder()).
			BorderStyle(lipgloss.NewStyle().Foreground(lipgloss.Color("#6c7086"))).
			Headers(headers...).
			Rows(rows...).
			StyleFunc(func(row, col int) lipgloss.Style {
				if row == -1 {
					return lipgloss.NewStyle().
						Foreground(lipgloss.Color("#89b4fa")).
						Bold(true).
						Padding(0, 1)
				}
				return lipgloss.NewStyle().
					Foreground(lipgloss.Color("#cdd6f4")).
					Padding(0, 1)
			})

		fmt.Println(t.Render())

		fmt.Println()
		fmt.Println(lipgloss.NewStyle().
			Foreground(lipgloss.Color("#6c7086")).
			Render("💡 Tip: Run with --verbose to see detailed service logs and health checks."))

		return nil
	},
}
