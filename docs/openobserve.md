# OpenObserve configuration

This document covers OpenObserve-side configuration for both telemetry streams.

## Streams

The stack writes to two log streams when the first records arrive:

- `dnslog` — RouterOS DNS query syslog messages
- `netflow` — GoFlow2 JSON records created from RouterOS Traffic-Flow

The OpenObserve built-in UDP/TCP syslog listener is intentionally not used. syslog-ng is the relay and HTTP/JSON ingestion client.

## 1. Start OpenObserve

```bash
cp .env.example .env
$EDITOR .env
docker compose up -d
```

Open:

```text
http://<collector-ip>:5080
```

Root credentials are used by OpenObserve during first initialization. For ongoing ingestion, dedicated ingestion credentials are preferable. Put the chosen credentials in `.env` because syslog-ng uses `OPENOBSERVE_USER` and `OPENOBSERVE_PASSWORD` for both streams.

## 2. DNS: verify raw ingestion

Before creating a DNS pipeline, generate a query through the MikroTik resolver and search the `dnslog` stream.

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

## 3. DNS: create `mikrotik_dns_parser`

Create a function named:

```text
mikrotik_dns_parser
```

Paste:

```text
openobserve/functions/mikrotik_dns_parser.vrl
```

Test input:

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

`dns_registered_domain` is Public-Suffix-List aware.

## 4. DNS: real-time pipeline

Recommended topology:

```text
dnslog Source
    ↓
mikrotik_dns_parser
    ↓
(optional) dns_filter
    ↓
(optional) Condition: dns_filter_drop = false
    ↓
dnslog Destination
```

Important: do not leave a second source-to-destination path that bypasses the parser/filter, otherwise filtered records still reach storage.

The pipeline affects new ingested records; old records are not rewritten automatically.

## 5. DNS: optional filter

Create:

```text
dns_filter
```

from:

```text
openobserve/functions/dns_filter.vrl
```

The default example suppresses PTR traffic for:

```text
in-addr.arpa
ip6.arpa
```

A rule has this form:

```json
{
  "record_type": "PTR",
  "domain_suffix": "in-addr.arpa"
}
```

Both attributes must match the same rule. `record_type="*"` matches any record type below the configured suffix.

The function only sets:

```text
dns_filter_drop = true|false
```

The following Condition must pass only:

```text
dns_filter_drop = false
```

## 6. DNS: optional client hostname enrichment

The parser always provides `dns_client_ip`. `dns_client_host` used by some dashboard queries is optional enrichment and is not produced by the base parser.

If an enrichment table maps LAN addresses to hostnames, add that lookup after `mikrotik_dns_parser` and populate `dns_client_host`. Otherwise use `dns_client_ip` directly in dashboards.

# NetFlow processing

## 7. Verify raw NetFlow ingestion

GoFlow2 already emits structured JSON and syslog-ng parses it before ingestion, so no format parser is required in OpenObserve.

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

Check the real event schema because NetFlow v9 is template-based and actual fields depend on the RouterOS exporter template and GoFlow2 version.

Use:

```sql
SELECT *
FROM "netflow"
ORDER BY _timestamp DESC
LIMIT 10;
```

## 8. Create `netflow_direction`

Create a function named:

```text
netflow_direction
```

from:

```text
openobserve/functions/netflow_direction.vrl
```

Default internal networks are:

```text
10.0.0.0/8
192.168.0.0/16
```

Edit the `internal_nets` array in the function if the monitored environment uses additional prefixes.

The function adds:

```text
internet_flow
direction
```

Classification:

| Source | Destination | direction | internet_flow |
|---|---|---|---|
| internal | external | `outbound` | `true` |
| external | internal | `inbound` | `true` |
| internal | internal | `internal` | `false` |
| external | external | `external` | `false` |

The function uses VRL `ip_cidr_contains()` and safely falls back to `false` for missing/invalid addresses.

## 9. Enable MaxMind MMDB support

OpenObserve exposes built-in enrichment tables:

```text
maxmind_city
maxmind_asn
```

Current OpenObserve defaults MMDB auto-download to disabled. This repository enables it in Compose and persists the files below the existing `/data` bind mount:

```dotenv
ZO_MMDB_DISABLE_DOWNLOAD=false
ZO_MMDB_DATA_DIR=/data/mmdb
ZO_MMDB_UPDATE_DURATION_DAYS=30
```

Host path:

```text
./data/openobserve/mmdb
```

The database and SHA256 URLs are configurable in `.env.example`.

Full MMDB lifecycle, validation and manual/air-gapped mode are documented in:

```text
docs/maxmind.md
```

Verify downloaded files:

```bash
find data/openobserve/mmdb -maxdepth 1 -type f -ls
```

## 10. Create `netflow_geoip`

Create a function named:

```text
netflow_geoip
```

from:

```text
openobserve/functions/netflow_geoip.vrl
```

It looks up both `src_addr` and `dst_addr` using `maxmind_city` and `maxmind_asn`.

Source fields added when a match exists:

```text
src_geo_country_code
src_geo_country_name
src_geo_city
src_geo_region
src_geo_timezone
src_geo_latitude
src_geo_longitude
src_geo_asn
src_geo_as_org
```

Destination fields:

```text
dst_geo_country_code
dst_geo_country_name
dst_geo_city
dst_geo_region
dst_geo_timezone
dst_geo_latitude
dst_geo_longitude
dst_geo_asn
dst_geo_as_org
```

Latitude/longitude are converted to floats and ASN to an integer. Missing MaxMind records, which are normal for private addresses, do not fail the event.

Test with:

```json
{
  "src_addr": "10.0.0.10",
  "dst_addr": "1.1.1.1"
}
```

The private source will normally remain unenriched while the public destination receives GeoIP/ASN fields.

## 11. Recommended NetFlow pipeline

To keep all flow classes:

```text
netflow Source
    ↓
netflow_direction
    ↓
netflow_geoip
    ↓
netflow Destination
```

To store only Internet traffic:

```text
netflow Source
    ↓
netflow_direction
    ↓
Condition: internet_flow = true
    ↓
netflow_geoip
    ↓
netflow Destination
```

Putting the Condition before GeoIP avoids unnecessary MaxMind lookups for flows that will be discarded.

As with DNS, do not leave a parallel bypass from Source directly to Destination.

## 12. Validate enriched NetFlow

Recent Internet flows:

```sql
SELECT
    _timestamp,
    src_addr,
    dst_addr,
    direction,
    internet_flow,
    src_geo_country_code,
    src_geo_asn,
    dst_geo_country_code,
    dst_geo_asn
FROM "netflow"
WHERE internet_flow = true
ORDER BY _timestamp DESC
LIMIT 50;
```

Outbound destinations by country:

```sql
SELECT
    dst_geo_country_code,
    COUNT(*) AS flows,
    SUM(bytes) AS bytes
FROM "netflow"
WHERE direction = 'outbound'
  AND dst_geo_country_code IS NOT NULL
GROUP BY dst_geo_country_code
ORDER BY bytes DESC
LIMIT 30;
```

Outbound destinations by ASN:

```sql
SELECT
    dst_geo_asn,
    dst_geo_as_org,
    COUNT(*) AS flows,
    SUM(bytes) AS bytes
FROM "netflow"
WHERE direction = 'outbound'
  AND dst_geo_asn IS NOT NULL
GROUP BY dst_geo_asn, dst_geo_as_org
ORDER BY bytes DESC
LIMIT 30;
```

## 13. Dashboard starter queries

DNS DGA analysis:

```text
openobserve/sql/dns_dga_score.sql
```

NetFlow overview:

```text
openobserve/sql/netflow_overview.sql
```

### DGA score interpretation

| DGA score | Interpretation |
|---:|---|
| 0–39.9 | normal / low signal |
| 40–59.9 | unusual |
| 60–74.9 | investigate |
| 75–100 | strongly DGA-like |

The DGA query exposes all raw component metrics and normalized component scores. Treat it as prioritization, not a malware verdict.

## 14. Retention

DNS query logging and NetFlow can generate high event volume. Configure stream-level retention appropriate to available storage after initial tuning.

## References

- OpenObserve documentation: https://openobserve.ai/docs/
- OpenObserve MaxMind enrichment examples: https://openobserve.ai/docs/user-guide/data-processing/enrichment-tables/enrichment-example/
- OpenObserve environment variables: https://openobserve.ai/docs/administration/configuration/environment-variables/
- OpenObserve JSON ingestion API: https://openobserve.ai/docs/reference/api/ingestion/logs/json/
- syslog-ng OpenObserve destination: https://syslog-ng.github.io/admin-guide/070_Destinations/153_OpenObserve/README.html
