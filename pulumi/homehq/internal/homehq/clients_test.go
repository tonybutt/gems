package homehq_test

import (
	"encoding/base64"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/tonybutt/gems/pulumi/homehq/internal/homehq"
)

func encode(json string) string {
	return base64.StdEncoding.EncodeToString([]byte(json))
}

const releaseServices = `{"client":[{"oauth_client":[
	{"client_id":"web.apps.googleusercontent.com","client_type":3},
	{"client_id":"release-b.apps.googleusercontent.com","client_type":1},
	{"client_id":"release-a.apps.googleusercontent.com","client_type":1}
]}]}`

const debugServices = `{"client":[{"oauth_client":[
	{"client_id":"debug.apps.googleusercontent.com","client_type":1},
	{"client_id":"release-a.apps.googleusercontent.com","client_type":1}
]}]}`

func TestAndroidClientIDsKeepsOnlyAndroidClientsSortedAndUnique(t *testing.T) {
	ids, err := homehq.AndroidClientIDs(encode(releaseServices), encode(debugServices))

	require.NoError(t, err)
	assert.Equal(t, []string{
		"debug.apps.googleusercontent.com",
		"release-a.apps.googleusercontent.com",
		"release-b.apps.googleusercontent.com",
	}, ids)
}

func TestAndroidClientIDsIsEmptyBeforeGoogleCreatesClients(t *testing.T) {
	ids, err := homehq.AndroidClientIDs(encode(`{"client":[{"oauth_client":[]}]}`))

	require.NoError(t, err)
	assert.Empty(t, ids)
}

func TestAndroidClientIDsRejectsMalformedFiles(t *testing.T) {
	_, err := homehq.AndroidClientIDs("not base64!")
	require.ErrorContains(t, err, "decoding google-services.json 0")

	_, err = homehq.AndroidClientIDs(encode("{"))
	require.ErrorContains(t, err, "parsing google-services.json 0")
}
