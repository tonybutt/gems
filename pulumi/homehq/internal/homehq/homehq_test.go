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
// locally, and records every registered resource.
type mocks struct {
	mu        sync.Mutex
	resources map[string]resource.PropertyMap
}

func (m *mocks) NewResource(args pulumi.MockResourceArgs) (string, resource.PropertyMap, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.resources[args.TypeToken+"::"+args.Name] = args.Inputs
	return args.Name + "-id", args.Inputs, nil
}

func (m *mocks) Call(args pulumi.MockCallArgs) (resource.PropertyMap, error) {
	return resource.PropertyMap{}, nil
}

func TestDeployCreatesProtectedProjectWithCalendarAPI(t *testing.T) {
	m := &mocks{resources: map[string]resource.PropertyMap{}}

	err := pulumi.RunErr(func(ctx *pulumi.Context) error {
		return homehq.Deploy(ctx, homehq.Config{OrgID: "123", ProjectID: "homehq-test"})
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
