# private-s3-pkg-repo

CLI lab: private multi-region RPM and deb repos on S3. Publish in Sydney,
replicate under `repos/` to Auckland, and install via `dnf` / `apt` from dual-OS
probes behind regional gateway VPC endpoints. A separate public UI bucket shows
a read-only catalog (not Pulp).

## Docs

```bash
npm install
npm run dev
```

Same layout as the other johna.kiwi walkthroughs (Concepts, Deploy and operate,
Reference).

## Lab

Docker is required during `up-shared` to build and push the rebuild Lambda
image to ECR. Index rebuild always runs in that Lambda (no laptop fallback).

```bash
export AWS_PROFILE=sandbox

./scripts/demo.sh up-shared
./scripts/demo.sh up-consumer syd
./scripts/demo.sh up-consumer akl
./scripts/demo.sh allowlist
./scripts/demo.sh publish
./scripts/demo.sh open-ui
./scripts/demo.sh prove syd
./scripts/demo.sh prove akl
./scripts/demo.sh down
```

Pages live under `src/content/docs/`.

## Out of scope

- Full Pulp (or other long-lived repo servers)
- Public package download from the catalog viewer
- Hosting the viewer on the private package buckets
- CodeBuild / schedule-first index rebuild
