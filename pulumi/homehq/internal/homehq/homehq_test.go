package homehq_test

import (
	"sync"
	"testing"

	"github.com/pulumi/pulumi/sdk/v3/go/common/resource"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonybutt/gems/pulumi/homehq/internal/homehq"
)

// mocks stands in for the GCP provider, the one seam that cannot run
// locally. It records registered resources and answers the Firebase
// config invoke with a google-services.json naming one Android client.
type mocks struct {
	mu        sync.Mutex
	resources map[string]resource.PropertyMap
}

func (m *mocks) NewResource(args pulumi.MockResourceArgs) (string, resource.PropertyMap, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.resources[args.TypeToken+"::"+args.Name] = args.Inputs

	outputs := args.Inputs.Copy()
	if args.TypeToken == "gcp:firebase/androidApp:AndroidApp" {
		outputs["appId"] = resource.NewStringProperty("app-" + args.Name)
	}
	return args.Name + "-id", outputs, nil
}

func (m *mocks) Call(args pulumi.MockCallArgs) (resource.PropertyMap, error) {
	appID := args.Args["appId"].StringValue()
	return resource.PropertyMap{
		"configFileContents": resource.NewStringProperty(encode(
			`{"client":[{"oauth_client":[{"client_id":"` + appID + `","client_type":1}]}]}`,
		)),
	}, nil
}

func deploy(t *testing.T, cfg homehq.Config) (*mocks, error) {
	t.Helper()
	m := &mocks{resources: map[string]resource.PropertyMap{}}
	err := pulumi.RunErr(func(ctx *pulumi.Context) error {
		return homehq.Deploy(ctx, cfg)
	}, pulumi.WithMocks("homehq-gcp", "test", m))
	return m, err
}

func validConfig() homehq.Config {
	return homehq.Config{
		OrgID:              "123",
		ProjectID:          "homehq-test",
		ReleaseFingerprint: []string{"AA:AA", "BB:BB"},
		DebugFingerprint:   []string{"CC:CC"},
	}
}

func TestDeployRegistersOneAndroidAppPerPackage(t *testing.T) {
	m, err := deploy(t, validConfig())
	require.NoError(t, err)

	release := m.resources["gcp:firebase/androidApp:AndroidApp::release"]
	require.NotNil(t, release)
	assert.Equal(t, homehq.ReleasePackage, release["packageName"].StringValue())
	assert.Len(t, release["sha1Hashes"].ArrayValue(), 2)

	debug := m.resources["gcp:firebase/androidApp:AndroidApp::debug"]
	require.NotNil(t, debug)
	assert.Equal(t, homehq.DebugPackage, debug["packageName"].StringValue())

	project := m.resources["gcp:organizations/project:Project::homehq"]
	require.NotNil(t, project)
	assert.Equal(t, "123", project["orgId"].StringValue())
	assert.Equal(t, "PREVENT", project["deletionPolicy"].StringValue())
}

func TestDeploySkipsDebugAppWithoutFingerprints(t *testing.T) {
	cfg := validConfig()
	cfg.DebugFingerprint = nil

	m, err := deploy(t, cfg)
	require.NoError(t, err)

	assert.NotContains(t, m.resources, "gcp:firebase/androidApp:AndroidApp::debug")
	assert.Contains(t, m.resources, "gcp:firebase/androidApp:AndroidApp::release")
}

func TestDeployRequiresAReleaseFingerprint(t *testing.T) {
	cfg := validConfig()
	cfg.ReleaseFingerprint = nil

	_, err := deploy(t, cfg)

	require.ErrorContains(t, err, "releaseSha1Fingerprints is empty")
}
