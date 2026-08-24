# OpenObserve configuration

This document covers the OpenObserve-side configuration for both telemetry streams.

## Streams

The stack writes to two log streams automatically when the first records arrive:

- `dnslog` — RouterOS DNS query syslog messages
- `netflow` — GoFlow2 JSON records created from RouterOS Traffic-Flow

The OpenObserve built-in UDP/TCP syslog listener is intentionally not used. Current OpenObserve documentation marks it as deprecated; syslog-ng is the relay and HTTP/JSON ingestion client instead.

## 1. Start OpenObserve

Copy the environment template and start the stack:

```bash
cp .env.example .env
$EDITOR .env
docker compose up -d
```

Open:

```text
http://<collector-ip>:5080
```

Root credentials are used by OpenObserve during first initialization. For ongoing ingestion, a dedicated ingestion account/token is preferable. Put the chosen ingestion credentials in `.env` because the syslog-ng container uses the same `OPENOBSERVE_USER` and `OPENOBSERVE_PASSWORD` values.

## 2. Verify raw DNS ingestion

Before creating any pipeline, generate a DNS query through the MikroTik DNS resolver and search the `dnslog` stream.

A raw event should contain at least:

```json
{
  "host": "router-name",
  "program": "dns",
  "priority": "notice",
  "message": "query from 10.254.249.10: #8630451 static.cloudflareinsights.com. A"
}
```

If `dnslog` is empty, troubleshoot RouterOS and syslog-ng before creating the parser.

## 3. Create the DNS parser function

Go to the OpenObserve Functions/Pipelines area and create a function named:

```text
mikrotik_dns_parser
```

Paste the complete contents of:

```text
openobserve/functions/mikrotik_dns_parser.vrl
```

Test it with:

```json
{
  "message": "query from 10.254.249.10: #8630451 static.cloudflareinsights.com. A"
}
```

Expected additional fields:

```json
{
  "dns_client_ip": "10.254.249.10",
  "dns_query_id": "8630451",
  "dns_domain": "static.cloudflareinsights.com",
  "dns_record_type": "A",
  "dns_tld": "com",
  "dns_public_suffix": "com",
  "dns_registered_domain": "cloudflareinsights.com"
}
```

`dns_registered_domain` is Public-Suffix-List aware. For example, a host under `example.co.uk` resolves to registered domain `example.co.uk`, not `co.uk`.

## 4. Create the real-time DNS pipeline

Recommended topology:

```text
dnslog source
    |
    v
mikrotik_dns_parser
    |
    +---------------------------+
    |                           |
    | optional                  |
    v                           |
dns_filter                     |
    |                           |
    v                           |
Condition:                      |
dns_filter_drop = false         |
    |                           |
    +---------------------------+
    |
    v
dnslog destination
```

Important: do not leave a second source-to-destination path that bypasses the parser/filter, otherwise filtered events will still be written through the bypass path.

The pipeline affects new ingested records. Existing records are not automatically rewritten.

## 5. Optional DNS filter

Create a second function named:

```text
dns_filter
```

using:

```text
openobserve/functions/dns_filter.vrl
```

The default example suppresses reverse-DNS PTR traffic for:

```text
in-addr.arpa
ip6.arpa
```

Rules have this form:

```json
{
  "record_type": "PTR",
  "domain_suffix": "in-addr.arpa"
}
```

Both attributes must match the same rule.

Use:

```json
{
  "record_type": "*",
  "domain_suffix": "telemetry.example.com"
}
```

to match every record type below one domain suffix.

The function only sets:

```text
dns_filter_drop = true|false
```

The following pipeline Condition must pass only:

```text
dns_filter_drop = false
```

## 6. Client hostname enrichment

The parser always provides `dns_client_ip`. The field `dns_client_host` used by some dashboard queries is optional enrichment and is not produced by the base parser.

If an OpenObserve enrichment table maps LAN addresses to hostnames, add the lookup after `mikrotik_dns_parser` and populate `dns_client_host`. Without enrichment, dashboard queries can use `dns_client_ip` directly.

## 7. NetFlow stream

No mandatory OpenObserve parsing function is required for `netflow` because GoFlow2 already outputs structured JSON and syslog-ng's `json-parser()` preserves those fields and their numeric types.

Typical fields include:

```text
type
sampler_address
src_addr
dst_addr
src_port
dst_port
proto
bytes
packets
time_received_ns
time_flow_start_ns
time_flow_end_ns
```

Check actual field availability in your RouterOS NetFlow v9 templates before building dashboards around optional fields.

## 8. Dashboard starter queries

DNS DGA analysis:

```text
openobserve/sql/dns_dga_score.sql
```

NetFlow overview:

```text
openobserve/sql/netflow_overview.sql
```

### DGA score interpretation

Suggested initial ranges:

| DGA score | Interpretation |
|---:|---|
| 0–39.9 | normal / low signal |
| 40–59.9 | unusual |
| 60–74.9 | investigate |
| 75–100 | strongly DGA-like |

The DGA query intentionally exposes all component metrics and component scores. Treat it as prioritization, not as a malware verdict.

## 9. Retention

DNS query logging can generate a large number of events. Configure stream-level retention appropriate to available storage. A short initial retention window is useful while tuning the parser, filters and dashboards.

## 10. Useful validation queries

Recent DNS records:

```sql
SELECT *
FROM "dnslog"
ORDER BY _timestamp DESC
LIMIT 20;
```

Top registered domains:

```sql
SELECT
    dns_registered_domain,
    COUNT(*) AS queries
FROM "dnslog"
WHERE dns_registered_domain IS NOT NULL
GROUP BY dns_registered_domain
ORDER BY queries DESC
LIMIT 20;
```

Recent NetFlow records:

```sql
SELECT *
FROM "netflow"
ORDER BY _timestamp DESC
LIMIT 20;
```

## References

- OpenObserve documentation: https://openobserve.ai/docs/
- OpenObserve JSON ingestion API: https://openobserve.ai/docs/reference/api/ingestion/logs/json/
- syslog-ng OpenObserve destination: https://syslog-ng.github.io/admin-guide/070_Destinations/153_OpenObserve/README.html
