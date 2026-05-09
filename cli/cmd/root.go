package cmd

import (
	"fmt"

	"github.com/charmbracelet/lipgloss"
	"github.com/spf13/cobra"
)

var (
	version = "dev"
	commit  = "none"
	date    = "unknown"
)

var rootCmd = &cobra.Command{
	Use:   "cococoir",
	Short: "Declarative self-hosting made simple",
	Long: lipgloss.NewStyle().
		Foreground(lipgloss.Color("#cba6f7")).
		Bold(true).
		Render("Cococoir") + " — " + lipgloss.NewStyle().
		Foreground(lipgloss.Color("#cdd6f4")).
		Render("Declarative self-hosting made simple.") + "\n\n" +
		"A CLI tool to scaffold, configure, and manage your Cococoir homelab.\n" +
		"Manage your NixOS deployment, add services, and provision infrastructure — all from one place.",
	SilenceUsage: true,
}

func Execute() error {
	return rootCmd.Execute()
}

func init() {
	rootCmd.AddCommand(versionCmd)
	rootCmd.AddCommand(initCmd)
	rootCmd.AddCommand(addCmd)
	rootCmd.AddCommand(statusCmd)
}

var versionCmd = &cobra.Command{
	Use:   "version",
	Short: "Print the version number",
	Run: func(cmd *cobra.Command, args []string) {
		fmt.Printf("cococoir version %s (commit: %s, built: %s)\n", version, commit, date)
	},
}
