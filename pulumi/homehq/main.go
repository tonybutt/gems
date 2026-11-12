package main

import (
	"fmt"

	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi/config"

	"github.com/tonybutt/gems/pulumi/homehq/internal/homehq"
)

func main() {
	pulumi.Run(func(ctx *pulumi.Context) error {
		cfg := config.New(ctx, "")

		var release, debug []string
		if err := cfg.GetObject("releaseSha1Fingerprints", &release); err != nil {
			return fmt.Errorf("reading releaseSha1Fingerprints: %w", err)
		}
		if err := cfg.GetObject("debugSha1Fingerprints", &debug); err != nil {
			return fmt.Errorf("reading debugSha1Fingerprints: %w", err)
		}

		return homehq.Deploy(ctx, homehq.Config{
			OrgID:              cfg.Require("orgId"),
			ProjectID:          cfg.Require("projectId"),
			ReleaseFingerprint: release,
			DebugFingerprint:   debug,
		})
	})
}
