export type GlossaryEntry =
  | string
  | {
      definition: string;
      url?: string;
      urlLabel?: string;
    };

export function resolveGlossaryEntry(entry: GlossaryEntry | undefined): {
  definition: string;
  url?: string;
  urlLabel?: string;
} {
  if (!entry) return { definition: "" };
  if (typeof entry === "string") return { definition: entry };
  return {
    definition: entry.definition,
    url: entry.url,
    urlLabel: entry.urlLabel,
  };
}

export const glossary: Record<string, GlossaryEntry> = {
  "gateway-vpce": {
    definition:
      "S3 gateway VPC endpoint. Route-table target that keeps S3 traffic on the AWS network; no hourly charge for the gateway itself.",
    url: "https://docs.aws.amazon.com/vpc/latest/privatelink/gateway-endpoints.html",
  },
  crr: {
    definition:
      "Cross-Region Replication. S3 copies objects (and versions) from a primary bucket to a replica in another Region.",
    url: "https://docs.aws.amazon.com/AmazonS3/latest/userguide/replication.html",
  },
  ha: {
    definition:
      "High availability. Design goal of staying usable through failures; multi-Region HA usually needs failover routing, not only a replica bucket.",
  },
  rpo: {
    definition:
      "Recovery point objective. How much data you can afford to lose after a failure, measured as time. Asynchronous replication means RPO is greater than zero.",
  },
  "source-vpce": {
    definition:
      "Bucket policy condition key aws:SourceVpce. Limits which VPC endpoint IDs can access the bucket.",
  },
  "xr-privatelink": {
    definition:
      "Cross-Region AWS PrivateLink for interface endpoints. Works for some Region pairs; not for ap-southeast-6 (Auckland) as of Sep 2026. Re-check before assuming coverage.",
  },
  createrepo: {
    definition:
      "createrepo_c builds yum/dnf repodata (repomd.xml and friends) for an RPM tree so dnf can resolve packages.",
  },
  "catalog-ui": {
    definition:
      "Public static website on the UI bucket. Shows catalog.json only; packages stay on the private S3 buckets and are not downloaded from this page.",
  },
};
