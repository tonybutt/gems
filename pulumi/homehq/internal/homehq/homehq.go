// Package homehq declares the Google Cloud project behind homehq sign-in
// and its Android OAuth clients.
//
// Google has no public API for standard OAuth 2.0 clients. Registering a
// Firebase Android app with SHA-1 fingerprints makes Google create one
// Android OAuth client per fingerprint, so the Firebase apps are how the
// Android clients are managed as code. The web client is made by hand
// (see README.md).
package homehq

import (
	"errors"
	"fmt"

	"github.com/pulumi/pulumi-gcp/sdk/v9/go/gcp"
	"github.com/pulumi/pulumi-gcp/sdk/v9/go/gcp/firebase"
	"github.com/pulumi/pulumi-gcp/sdk/v9/go/gcp/organizations"
	"github.com/pulumi/pulumi-gcp/sdk/v9/go/gcp/projects"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
)

const (
	ReleasePackage = "dev.abutt.homehq"
	DebugPackage   = ReleasePackage + ".debug"
)

var services = []string{
	"firebase.googleapis.com",
	"serviceusage.googleapis.com",
	"calendar-json.googleapis.com",
}

// Config is the stack configuration.
type Config struct {
	OrgID     string
	ProjectID string
	// ReleaseFingerprint holds the SHA-1s allowed to sign ReleasePackage:
	// the upload key and the Play app-signing key.
	ReleaseFingerprint []string
	// DebugFingerprint holds the debug keystore SHA-1s for DebugPackage.
	// Empty skips the debug app.
	DebugFingerprint []string
}

// Deploy registers the project, its APIs, Firebase, and one Firebase Android
// app per package. It exports the project ID and the Android client IDs.
func Deploy(ctx *pulumi.Context, cfg Config) error {
	if len(cfg.ReleaseFingerprint) == 0 {
		return errors.New("releaseSha1Fingerprints is empty: set at least the upload key SHA-1")
	}

	project, err := organizations.NewProject(ctx, "homehq", &organizations.ProjectArgs{
		Name:           pulumi.String("Home HQ"),
		ProjectId:      pulumi.String(cfg.ProjectID),
		OrgId:          pulumi.String(cfg.OrgID),
		DeletionPolicy: pulumi.String("PREVENT"),
		Labels:         pulumi.StringMap{"firebase": pulumi.String("enabled")},
	}, pulumi.Protect(true))
	if err != nil {
		return fmt.Errorf("creating project: %w", err)
	}

	// Enabling APIs must not bill against the project: its APIs are still
	// off. Everything after bills against it, because Firebase Management
	// calls made with user (ADC) credentials need a quota project.
	enabled := make([]pulumi.Resource, 0, len(services))
	for _, service := range services {
		s, err := projects.NewService(ctx, service, &projects.ServiceArgs{
			Project:          project.ProjectId,
			Service:          pulumi.String(service),
			DisableOnDestroy: pulumi.Bool(false),
		})
		if err != nil {
			return fmt.Errorf("enabling %s: %w", service, err)
		}
		enabled = append(enabled, s)
	}

	quota, err := gcp.NewProvider(ctx, "homehq", &gcp.ProviderArgs{
		Project:             project.ProjectId,
		BillingProject:      project.ProjectId,
		UserProjectOverride: pulumi.Bool(true),
	})
	if err != nil {
		return fmt.Errorf("creating quota-project provider: %w", err)
	}

	fb, err := firebase.NewProject(ctx, "homehq", &firebase.ProjectArgs{
		Project: project.ProjectId,
	}, pulumi.Provider(quota), pulumi.DependsOn(enabled))
	if err != nil {
		return fmt.Errorf("adding Firebase: %w", err)
	}

	apps := []struct {
		name, display, pkg string
		fingerprints       []string
	}{
		{"release", "Home HQ", ReleasePackage, cfg.ReleaseFingerprint},
		{"debug", "Home HQ (dev)", DebugPackage, cfg.DebugFingerprint},
	}

	var configs []any
	for _, a := range apps {
		if len(a.fingerprints) == 0 {
			continue
		}
		app, err := firebase.NewAndroidApp(ctx, a.name, &firebase.AndroidAppArgs{
			Project:        fb.Project,
			DisplayName:    pulumi.String(a.display),
			PackageName:    pulumi.String(a.pkg),
			Sha1Hashes:     pulumi.ToStringArray(a.fingerprints),
			DeletionPolicy: pulumi.String("DELETE"),
		}, pulumi.Provider(quota))
		if err != nil {
			return fmt.Errorf("registering Android app %s: %w", a.pkg, err)
		}
		config := firebase.GetAndroidAppConfigOutput(ctx, firebase.GetAndroidAppConfigOutputArgs{
			Project: fb.Project,
			AppId:   app.AppId,
		}, pulumi.Provider(quota))
		configs = append(configs, config.ConfigFileContents())
	}

	clientIDs := pulumi.All(configs...).ApplyT(func(contents []any) ([]string, error) {
		files := make([]string, len(contents))
		for i, c := range contents {
			files[i] = c.(string)
		}
		return AndroidClientIDs(files...)
	}).(pulumi.StringArrayOutput)

	ctx.Export("projectId", project.ProjectId)
	ctx.Export("androidClientIds", clientIDs)
	return nil
}
