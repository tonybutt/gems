# homehq Google Cloud

The Google Cloud project behind homehq (the `family-task` app) sign-in, in the
abutt.io Workspace organization. A Pulumi program in Go.

## What is code and what is not

| Piece                                       | How                           |
| ------------------------------------------- | ----------------------------- |
| Project `homehq-abutt` in the abutt.io org  | Pulumi                        |
| Calendar API                                | Pulumi                        |
| OAuth consent screen (Google Auth Platform) | Console, once                 |
| Web OAuth client                            | Console, once                 |
| Android OAuth clients                       | Console, once per signing key |

Google has no public API for the consent screen or for standard OAuth 2.0
clients (checked November 2026):

- The IAP OAuth Admin API, the only one that could create a consent screen
  and clients, shut down on 2026-03-19.
  `google_iap_brand` and `google_iap_client` no longer work.
- `gcloud iam oauth-clients` and `google_iam_oauth_client` are Workforce
  Identity OAuth apps for IAP and Looker, not Sign in with Google clients.
- Firebase creates Android clients only after Google sign-in is enabled in
  Firebase Auth, and that needs an existing web client ID and secret, so it
  saves no manual step.

## Apply

From the gems devshell. It ships `gcloud`, `pulumi` and `go`, and sets the
Pulumi backend and passphrase:

```sh
gcloud auth application-default login     # once, as anthony@abutt.io
pulumi -C pulumi/homehq up
```

Without application-default credentials, prefix the command with
`GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud auth print-access-token)`; the token
lasts an hour, so it is not set in the devshell.

`Pulumi.prod.yaml` holds the org and project IDs; nothing in the stack is
secret. State lives in `~/.pulumi` on this machine. If you lose it, run
`pulumi import gcp:organizations/project:Project homehq homehq-abutt` and
import each `gcp:projects/service:Service` as `homehq-abutt/<api>`. The
project is protected and `deletionPolicy: PREVENT`, so `pulumi destroy`
cannot remove it.

Tests: `go test -race ./...` (the GCP provider is mocked).

## Console steps

All in <https://console.cloud.google.com/auth?project=homehq-abutt>.

1. **Branding / Audience** (done 2026-11-12): app name "Home HQ", privacy
   policy `https://homehq.abutt.dev/privacy/`, audience **External** (parents
   in `PARENT_ALLOW_LIST` outside abutt.io cannot sign in to an Internal
   app). In Testing mode, add each parent as a test user. Calendar scopes
   are sensitive, so publishing to production needs verification.
2. **Data access**: `openid`, `email`, `profile`,
   `.../auth/calendar.readonly`, `.../auth/calendar.events`.
3. **Clients > Create client > Web application**, named "homehq web".
   Authorized redirect URIs:
   - `https://homehq.abutt.dev/api/auth/google/callback`
   - `http://localhost:30300/api/auth/google/callback`
4. **Clients > Create client > Android**, one per signing key, package
   `dev.abutt.homehq`:
   - Upload key: `3C:69:5D:86:C1:11:7E:D0:0B:C9:49:EB:F6:8E:94:49:10:1B:69:D8`
     (`nix run .#android-keystore-init` in the task repo prints it).
   - Play app-signing key: Play Console > App integrity.
   - Debug builds: package `dev.abutt.homehq.debug` with your debug keystore
     SHA-1 (`keytool -list -v -keystore ~/.android/debug.keystore
-storepass android`).

   A package + SHA-1 pair can belong to only one OAuth client across all of
   Google, including clients in soft-deleted projects. A 409 "already exists
   in a different project" means an old client still holds it: delete that
   client first.

## Wire the clients into homehq

| Value                                                                          | Where                                                 |
| ------------------------------------------------------------------------------ | ----------------------------------------------------- |
| Web client ID and secret: `AUTH_GOOGLE_CLIENT_ID`, `AUTH_GOOGLE_CLIENT_SECRET` | `apps/homehq/secrets/homehq-api.encrypted.env` (sops) |
| Android client IDs, comma-joined: `AUTH_GOOGLE_NATIVE_CLIENT_IDS`              | same file                                             |
| Web client ID: `WEB_CLIENT_ID`                                                 | Android build in the task repo, then ship a release   |

Calendar refresh tokens from the old personal project died with its client,
so each parent signs in again.
