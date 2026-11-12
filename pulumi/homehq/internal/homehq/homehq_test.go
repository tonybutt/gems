package homehq_test

import (
	"encoding/base64"
	"sync"
	"testing"

	"github.com/pulumi/pulumi/sdk/v3/go/common/resource"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonybutt/gems/pulumi/homehq/internal/homehq"
)

// mocks stands in for the GCP provider, the one seam that cannot run
// locally, and records every registered resource. outputs adds
// provider-computed properties by type token.
type mocks struct {
	mu        sync.Mutex
	resources map[string]resource.PropertyMap
	outputs   map[string]resource.PropertyMap
}

func newMocks() *mocks {
	return &mocks{
		resources: map[string]resource.PropertyMap{},
		outputs:   map[string]resource.PropertyMap{},
	}
}

func (m *mocks) NewResource(args pulumi.MockResourceArgs) (string, resource.PropertyMap, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.resources[args.TypeToken+"::"+args.Name] = args.Inputs
	state := args.Inputs.Copy()
	for k, v := range m.outputs[args.TypeToken] {
		state[k] = v
	}
	return args.Name + "-id", state, nil
}

func (m *mocks) Call(args pulumi.MockCallArgs) (resource.PropertyMap, error) {
	return resource.PropertyMap{}, nil
}

func TestDeployCreatesProtectedProjectWithCalendarAPI(t *testing.T) {
	m := newMocks()

	err := pulumi.RunErr(func(ctx *pulumi.Context) error {
		_, err := homehq.Deploy(ctx, homehq.Config{OrgID: "123", ProjectID: "homehq-test"})
		return err
	}, pulumi.WithMocks("homehq-gcp", "test", m))
	require.NoError(t, err)

	project := m.resources["gcp:organizations/project:Project::homehq"]
	require.NotNil(t, project)
	assert.Equal(t, "123", project["orgId"].StringValue())
	assert.Equal(t, "homehq-test", project["projectId"].StringValue())
	assert.Equal(t, "PREVENT", project["deletionPolicy"].StringValue())

	calendar := m.resources["gcp:projects/service:Service::calendar-json.googleapis.com"]
	require.NotNil(t, calendar)
	assert.Equal(t, "homehq-test", calendar["project"].StringValue())
	assert.False(t, calendar["disableOnDestroy"].BoolValue())
}

func TestDeployCreatesPlayPublisherWithSecretJSONKey(t *testing.T) {
	m := newMocks()
	keyJSON := `{"type":"service_account","client_email":"play-publisher@homehq-test.iam.gserviceaccount.com"}`
	m.outputs["gcp:serviceaccount/account:Account"] = resource.PropertyMap{
		"name": resource.NewStringProperty("projects/homehq-test/serviceAccounts/play-publisher@homehq-test.iam.gserviceaccount.com"),
	}
	m.outputs["gcp:serviceaccount/key:Key"] = resource.PropertyMap{
		"privateKey": resource.NewStringProperty(base64.StdEncoding.EncodeToString([]byte(keyJSON))),
	}

	var out homehq.Outputs
	var got string
	err := pulumi.RunErr(func(ctx *pulumi.Context) error {
		var err error
		out, err = homehq.Deploy(ctx, homehq.Config{OrgID: "123", ProjectID: "homehq-test"})
		if err != nil {
			return err
		}
		out.PlayPublisherKey.ApplyT(func(v string) string {
			got = v
			return v
		})
		return nil
	}, pulumi.WithMocks("homehq-gcp", "test", m))
	require.NoError(t, err)

	for _, api := range []string{"androidpublisher.googleapis.com", "iam.googleapis.com"} {
		assert.NotNil(t, m.resources["gcp:projects/service:Service::"+api], api)
	}

	account := m.resources["gcp:serviceaccount/account:Account::play-publisher"]
	require.NotNil(t, account)
	assert.Equal(t, "play-publisher", account["accountId"].StringValue())
	assert.Equal(t, "homehq-test", account["project"].StringValue())

	key := m.resources["gcp:serviceaccount/key:Key::play-publisher"]
	require.NotNil(t, key)
	assert.Equal(t, "projects/homehq-test/serviceAccounts/play-publisher@homehq-test.iam.gserviceaccount.com", key["serviceAccountId"].StringValue())

	assert.Equal(t, keyJSON, got, "the export is the decoded JSON key file")
	assert.True(t, pulumi.IsSecret(out.PlayPublisherKey), "the key must be exported as a secret")
}
