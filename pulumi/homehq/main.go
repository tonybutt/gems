package main

import (
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi/config"

	"github.com/tonybutt/gems/pulumi/homehq/internal/homehq"
)

func main() {
	pulumi.Run(func(ctx *pulumi.Context) error {
		cfg := config.New(ctx, "")
		_, err := homehq.Deploy(ctx, homehq.Config{
			OrgID:     cfg.Require("orgId"),
			ProjectID: cfg.Require("projectId"),
		})
		return err
	})
}
