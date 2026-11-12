package homehq

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"slices"
)

// androidClientType is the google-services.json client_type of an Android
// OAuth client.
const androidClientType = 1

type googleServices struct {
	Client []struct {
		OAuthClient []struct {
			ClientID   string `json:"client_id"`
			ClientType int    `json:"client_type"`
		} `json:"oauth_client"`
	} `json:"client"`
}

// AndroidClientIDs returns the sorted, de-duplicated Android OAuth client
// IDs listed in base64-encoded google-services.json files. It is empty
// until Google has created the clients.
func AndroidClientIDs(files ...string) ([]string, error) {
	var ids []string
	for i, file := range files {
		raw, err := base64.StdEncoding.DecodeString(file)
		if err != nil {
			return nil, fmt.Errorf("decoding google-services.json %d: %w", i, err)
		}
		var gs googleServices
		if err := json.Unmarshal(raw, &gs); err != nil {
			return nil, fmt.Errorf("parsing google-services.json %d: %w", i, err)
		}
		for _, client := range gs.Client {
			for _, oauth := range client.OAuthClient {
				if oauth.ClientType == androidClientType {
					ids = append(ids, oauth.ClientID)
				}
			}
		}
	}
	slices.Sort(ids)
	return slices.Compact(ids), nil
}
