# Maven repository actions

GitHub Actions that publish a release into the ConfigDirector Maven repository,
`https://maven.configdirector.com`. The repository is a Cloudflare R2 bucket behind a custom domain,
and these actions are the only thing that writes to it. The SDK repositories that use them:
[java-sdks](https://github.com/ConfigDirector/java-sdks) and
[android-sdk](https://github.com/ConfigDirector/android-sdk).

Two actions share one script:

| Action | What it does |
| --- | --- |
| `check` | Fails when any of the given versions already has a POM in the bucket. Run it before building, so a release that would be refused costs nothing. |
| `upload` | Runs the same check, attests every jar and POM, then uploads the versions from a staging Maven repository the build published into. |

## Usage

The release job runs in a GitHub environment that holds the bucket's credentials, `maven-dev` or
`maven-prod`. The build publishes signed artifacts into a staging directory, by default
`build/maven-repository`, with Gradle's `maven-publish` plugin pointed at a local repository.

```yaml
jobs:
  publish:
    runs-on: ubuntu-latest
    environment: maven-${{ inputs.repository }}
    permissions:
      contents: write
      id-token: write
      attestations: write
    steps:
      - uses: actions/checkout@v5

      - name: Refuse a version that is already in the Maven repository
        uses: ConfigDirector/maven-repository-actions/check@v1
        with:
          bucket: ${{ vars.MAVEN_REPOSITORY_BUCKET }}
          endpoint: ${{ vars.MAVEN_REPOSITORY_ENDPOINT }}
          access-key-id: ${{ secrets.MAVEN_REPOSITORY_ACCESS_KEY_ID }}
          secret-access-key: ${{ secrets.MAVEN_REPOSITORY_SECRET_ACCESS_KEY }}
          artifacts: |
            com.configdirector:server-sdk:1.8.0
            com.configdirector:server-sdk-testing:1.8.0

      # Build, test and publish the signed release into build/maven-repository here.

      - name: Upload to the Maven repository
        uses: ConfigDirector/maven-repository-actions/upload@v1
        with:
          bucket: ${{ vars.MAVEN_REPOSITORY_BUCKET }}
          endpoint: ${{ vars.MAVEN_REPOSITORY_ENDPOINT }}
          access-key-id: ${{ secrets.MAVEN_REPOSITORY_ACCESS_KEY_ID }}
          secret-access-key: ${{ secrets.MAVEN_REPOSITORY_SECRET_ACCESS_KEY }}
          artifacts: |
            com.configdirector:server-sdk:1.8.0
            com.configdirector:server-sdk-testing:1.8.0
```

### Inputs

| Input | `check` | `upload` | Meaning |
| --- | --- | --- | --- |
| `bucket` | required | required | Name of the R2 bucket. |
| `endpoint` | required | required | S3 endpoint of the bucket, `https://<account id>.r2.cloudflarestorage.com`. |
| `access-key-id` | required | required | Access key ID of an R2 API token with Object Read & Write on the bucket. |
| `secret-access-key` | required | required | Secret access key of that token. |
| `artifacts` | required | required | The versions, one `group:artifactId:version` per line. |
| `staging-directory` | | `build/maven-repository` | Where the build published the release. |
| `attest` | | `true` | Create GitHub build attestations for the jars and POMs. Needs the `id-token` and `attestations` write permissions on the job. |

The runner needs the AWS CLI, which GitHub's Ubuntu runners include.

## What `upload` guarantees

- **A version is only advertised once it is complete.** For every version it uploads the version's
  files first, then the POM, then the artifact's `maven-metadata.xml` with its checksums. Clients
  only learn about a version from the POM and the metadata, so a run that fails halfway leaves
  nothing a client would pick up.
- **A released version is never replaced.** A version whose POM is already in the bucket is refused
  before anything is uploaded, naming the version and the key. A run that failed before the POM went
  up can simply be run again; a finished version needs a new version number.
- **The metadata lists every released version.** `maven-metadata.xml` is rewritten from the bucket's
  contents, every version directory that holds a POM plus the one being released, so it is correct
  even if an earlier metadata file was not.
- **Metadata is never served stale.** `maven-metadata.xml` and its checksums are uploaded with
  `Cache-Control: no-cache`, which the repository's cache rules turn into a revalidation on every
  use and a five minute lifetime for clients. Version files carry no header and are cached for a
  year.
- **Every jar and POM has provenance.** `gh attestation verify <file> --owner ConfigDirector` passes
  for each one after the release.

## Development

```bash
test/maven-repository.test.sh
```

The tests run the script against a stubbed `aws` command, `test/aws-stub.sh`, that keeps a bucket in
a temporary directory and records every call. CI runs them, lints the actions with actionlint, and
runs both actions end to end against the same stub.

## Releasing a new version of the actions

Callers pin the major version, `@v1`. After merging a change:

1. Tag the commit with the full version, for example `v1.1.0`, and push the tag.
2. Move the major tag to the same commit and force push it:

   ```bash
   git tag -fa v1 -m "v1.1.0" && git push --force origin v1
   ```

A change that breaks an input or a guarantee above gets a new major version and a new major tag,
and the callers opt in by changing `@v1`.
