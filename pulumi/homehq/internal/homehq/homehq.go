// Package homehq declares the Google Cloud project behind homehq sign-in.
//
// Google has no public API for the OAuth consent screen or for standard
// OAuth 2.0 clients (web and Android), so those are made by hand in the
// console (see README.md). This package owns what does have an API: the
// project, its place in the organization, the APIs it enables, and the
// service account that uploads Play releases.
package homehq

import (
	"encoding/base64"
	"fmt"

	"github.com/pulumi/pulumi-gcp/sdk/v9/go/gcp/organizations"
	"github.com/pulumi/pulumi-gcp/sdk/v9/go/gcp/projects"
	"github.com/pulumi/pulumi-gcp/sdk/v9/go/gcp/serviceaccount"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
)

var services = []string{
	"serviceusage.googleapis.com",
	"calendar-json.googleapis.com",
	"iam.googleapis.com",
	"androidpublisher.googleapis.com",
}

// Config is the stack configuration.
type Config struct {
	OrgID     string
	ProjectID string
}

// Outputs are the values Deploy exports, returned for tests.
type Outputs struct {
	PlayPublisherKey pulumi.StringOutput
}

// Deploy registers the project, enables its APIs and creates the Play
// publisher service account with a JSON key. It exports the project ID,
// the service account email and the key (as a secret).
func Deploy(ctx *pulumi.Context, cfg Config) (Outputs, error) {
	project, err := organizations.NewProject(ctx, "homehq", &organizations.ProjectArgs{
		Name:           pulumi.String("Home HQ"),
		ProjectId:      pulumi.String(cfg.ProjectID),
		OrgId:          pulumi.String(cfg.OrgID),
		DeletionPolicy: pulumi.String("PREVENT"),
	}, pulumi.Protect(true))
	if err != nil {
		return Outputs{}, fmt.Errorf("creating project: %w", err)
	}

	enabled := make([]pulumi.Resource, 0, len(services))
	for _, service := range services {
		svc, err := projects.NewService(ctx, service, &projects.ServiceArgs{
			Project:          project.ProjectId,
			Service:          pulumi.String(service),
			DisableOnDestroy: pulumi.Bool(false),
		})
		if err != nil {
			return Outputs{}, fmt.Errorf("enabling %s: %w", service, err)
		}
		enabled = append(enabled, svc)
	}

	// No project roles: Play permissions are granted to this account in
	// the Play Console.
	publisher, err := serviceaccount.NewAccount(ctx, "play-publisher", &serviceaccount.AccountArgs{
		Project:     project.ProjectId,
		AccountId:   pulumi.String("play-publisher"),
		DisplayName: pulumi.String("Play publisher"),
		Description: pulumi.String("Uploads homehq Android releases to Google Play."),
	}, pulumi.DependsOn(enabled))
	if err != nil {
		return Outputs{}, fmt.Errorf("creating play publisher service account: %w", err)
	}

	key, err := serviceaccount.NewKey(ctx, "play-publisher", &serviceaccount.KeyArgs{
		ServiceAccountId: publisher.Name,
	})
	if err != nil {
		return Outputs{}, fmt.Errorf("creating play publisher key: %w", err)
	}

	// PrivateKey is the base64 of the JSON key file Play tooling expects.
	keyJSON := key.PrivateKey.ApplyT(func(encoded string) (string, error) {
		raw, err := base64.StdEncoding.DecodeString(encoded)
		if err != nil {
			return "", fmt.Errorf("decoding play publisher key: %w", err)
		}
		return string(raw), nil
	}).(pulumi.StringOutput)

	ctx.Export("projectId", project.ProjectId)
	ctx.Export("playPublisherEmail", publisher.Email)
	secretKey := pulumi.ToSecret(keyJSON).(pulumi.StringOutput)
	ctx.Export("playPublisherKey", secretKey)
	return Outputs{PlayPublisherKey: secretKey}, nil
}
