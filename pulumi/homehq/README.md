# homehq Google Cloud

The Google Cloud project behind homehq (the `family-task` app) sign-in, in the
abutt.io Workspace organization. It replaces the project in the personal
Google account. A Pulumi program in Go.

## What is code and what is not

Google has no public API for standard OAuth 2.0 clients, so no IaC tool can
create them directly.

| Piece                                                                | How                                                                                |
| -------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| Project, APIs (Firebase, Calendar)                                   | Pulumi                                                                             |
| Android OAuth clients (`dev.abutt.homehq`, `dev.abutt.homehq.debug`) | Pulumi, through Firebase Android apps. Google creates one Android client per SHA-1 |
| OAuth consent screen (Google Auth Platform)                          | Console, once                                                                      |
| Web OAuth client (login, Calendar, Android `serverClientId`)         | Console, once                                                                      |

## Apply

From the gems devshell (it ships `gcloud`, `pulumi` and `go`):

```sh
gcloud auth login anthony@abutt.io
gcloud auth application-default login
gcloud organizations list                  # copy the abutt.io org ID

cd pulumi/homehq
pulumi login --local                       # state in ~/.pulumi
export PULUMI_CONFIG_PASSPHRASE=           # the stack holds no secrets
pulumi stack init prod
cp Pulumi.prod.yaml.example Pulumi.prod.yaml
$EDITOR Pulumi.prod.yaml                   # org ID and SHA-1s; none of it is secret
pulumi up
```

Commit `Pulumi.prod.yaml`. State lives in `~/.pulumi` on this machine. If you
lose it, `pulumi import` the project and the Firebase apps
(`projects/<id>/androidApps/<app id>`) rather than re-creating them. The
project is protected and `deletionPolicy: PREVENT`, so `pulumi destroy`
cannot remove it.

`androidClientIds` can be empty on the first `up` while Google is still
creating the clients. Run `pulumi up` again to read them.

Tests: `go test -race ./...` (the GCP provider is mocked).

## Console steps (once)

In <https://console.cloud.google.com/auth> for the new project:

1. **Branding / Audience**: app name "Home HQ", privacy policy
   `https://homehq.abutt.dev/privacy/`. Choose **External**: parents in
   `PARENT_ALLOW_LIST` outside abutt.io cannot sign in to an Internal app.
   In Testing mode, add each parent as a test user. Calendar scopes are
   sensitive, so publishing to production needs verification.
2. **Data access**: `openid`, `email`, `profile`,
   `.../auth/calendar.readonly`, `.../auth/calendar.events`.
3. **Clients > Create client > Web application**, named "homehq web".
   Authorized redirect URIs:
   - `https://homehq.abutt.dev/api/auth/google/callback`
   - `http://localhost:30300/api/auth/google/callback`

## Cut over from the old project

New project means new client IDs, so each consumer changes once:

| Value                                                                                 | Where                                                 |
| ------------------------------------------------------------------------------------- | ----------------------------------------------------- |
| Web client ID and secret: `AUTH_GOOGLE_CLIENT_ID`, `AUTH_GOOGLE_CLIENT_SECRET`        | `apps/homehq/secrets/homehq-api.encrypted.env` (sops) |
| `pulumi stack output androidClientIds`, comma-joined: `AUTH_GOOGLE_NATIVE_CLIENT_IDS` | same file                                             |
| Web client ID: `WEB_CLIENT_ID`                                                        | Android build in the task repo, then ship a release   |

Calendar refresh tokens are tied to the old client, so each parent signs in
again after the cutover. Delete the old OAuth clients in the personal
project only after the new release is on every device.
