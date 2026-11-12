// Package homehq declares the Google Cloud project behind homehq sign-in.
//
// Google has no public API for the OAuth consent screen or for standard
// OAuth 2.0 clients (web and Android), so those are made by hand in the
// console (see README.md). This package owns what does have an API: the
// project, its place in the organization, and the APIs it enables.
package homehq

import (
	"fmt"

	"github.com/pulumi/pulumi-gcp/sdk/v9/go/gcp/organizations"
	"github.com/pulumi/pulumi-gcp/sdk/v9/go/gcp/projects"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
)

var services = []string{
	"serviceusage.googleapis.com",
	"calendar-json.googleapis.com",
}

// Config is the stack configuration.
type Config struct {
	OrgID     string
	ProjectID string
}

// Deploy registers the project and enables its APIs. It exports the
// project ID.
func Deploy(ctx *pulumi.Context, cfg Config) error {
	project, err := organizations.NewProject(ctx, "homehq", &organizations.ProjectArgs{
		Name:           pulumi.String("Home HQ"),
		ProjectId:      pulumi.String(cfg.ProjectID),
		OrgId:          pulumi.String(cfg.OrgID),
		DeletionPolicy: pulumi.String("PREVENT"),
	}, pulumi.Protect(true))
	if err != nil {
		return fmt.Errorf("creating project: %w", err)
	}

	for _, service := range services {
		_, err := projects.NewService(ctx, service, &projects.ServiceArgs{
			Project:          project.ProjectId,
			Service:          pulumi.String(service),
			DisableOnDestroy: pulumi.Bool(false),
		})
		if err != nil {
			return fmt.Errorf("enabling %s: %w", service, err)
		}
	}

	ctx.Export("projectId", project.ProjectId)
	return nil
}
