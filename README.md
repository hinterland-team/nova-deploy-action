# Nova Deploy build step

The shared GitHub Actions step behind Nova Deploy ("Vercel for OrionStar robots"). It tests and builds the Android apps listed in a repo's `nova-deploy.json`, signs them with the team's key and publishes one GitHub release per app and build. The Nova Deploy app on the robot installs those releases.

You normally don't add this by hand: "Set it up" on the Nova Deploy dashboard writes the workflow and the secrets into your repo.

## What it does

1. Checks out your repo (the pushed commit, or `sha` for a redeploy) into `src/`.
2. Checks that the signing key opens with its password.
3. For every Gradle project in `nova-deploy.json`: writes `local.properties` (your `app-properties` lines plus the signing keys), runs `testDebugUnitTest`.
4. Builds every app with `versionCode = 1000 + run number` and `versionName = b<N>-<sha7>`, checks package, version and signature of each APK.
5. Publishes a release per app: tag `<id>-b<N>`, the APK as asset, the build info as a JSON block in the release text.

## Inputs

| input | what |
|---|---|
| `sha` | full commit sha to build, empty = the commit that started the workflow |
| `keystore` | base64 of the signing keystore (secret `NOVA_KEYSTORE_B64`) |
| `keystore-password` | its password (secret `NOVA_KEYSTORE_PASSWORD`) |
| `app-properties` | optional `local.properties` lines your app needs at build time (secret `NOVA_APP_PROPERTIES`) |
| `github-token` | `${{ github.token }}`, needs `contents: write` |

## nova-deploy.json

```json
{ "apps": [ { "id": "my-app", "name": "My App", "project": "android", "module": "app", "package": "com.example.myapp", "launch": "home" } ] }
```

Your Gradle build has to read `-PversionCode` / `-PversionName` and sign the debug build with `signing.storeFile`, `signing.storePassword`, `signing.keyAlias`, `signing.keyPassword` from `local.properties`.
