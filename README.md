# MikroTik → OpenObserve DNS + NetFlow stack

A reproducible Docker Compose stack for collecting and enriching telemetry from MikroTik RouterOS:

- **DNS queries**: RouterOS remote syslog → syslog-ng → OpenObserve `dnslog`
- **NetFlow v9**: RouterOS Traffic-Flow → GoFlow2 → FIFO → syslog-ng → OpenObserve `netflow`
- **NetFlow enrichment**: direction classification + MaxMind City/ASN

The design intentionally keeps OpenObserve's deprecated built-in syslog listener out of the data path. syslog-ng is the common HTTP/JSON ingestion client for OpenObserve.

## Architecture

```text
                      +-----------------------+
                      |       MikroTik        |
                      +-----------+-----------+
                                  |
                 +----------------+----------------+
                 |                                 |
       DNS syslog UDP/5514              NetFlow v9 UDP/2055
                 |                                 |
                 v                                 v
        +----------------+                +----------------+
        |   syslog-ng    |                |    GoFlow2     |
        +-------+--------+                +-------+--------+
                |                                 |
                |                          JSON to FIFO
                |                                 |
                +----------------+----------------+
                                 |
                                 v
                      +-----------------------+
                      |      syslog-ng        |
                      | openobserve-log()     |
                      +-----------+-----------+
                                  |
                     +------------+------------+
                     |                         |
                     v                         v
               stream: dnslog           stream: netflow
                     |                         |
                     v                         v
            mikrotik_dns_parser       netflow_direction
                     |                         |
                 dns_filter              netflow_geoip
```

GoFlow2 uses a FIFO instead of an intermediate `flows.log`, so there is no unbounded transient flow file to rotate.

## Components

Default image versions/tags are pinned in `.env.example`:

| Component | Default |
|---|---|
| OpenObserve | `v0.92.2` |
| GoFlow2 | `v2` branch image `2d10ea3` |
| syslog-ng | `4.12.0` |
| Alpine init image | `3.23` |

## Repository layout

```text
.
├── docker-compose.yml
├── .env.example
├── .gitignore
├── config/
│   ├── mikrotik/
│   │   └── routeros.rsc
│   └── syslog-ng/
│       └── syslog-ng.conf
├── openobserve/
│   ├── functions/
│   │   ├── mikrotik_dns_parser.vrl
│   │   ├── dns_filter.vrl
│   │   ├── netflow_direction.vrl
│   │   └── netflow_geoip.vrl
│   └── sql/
│       ├── dns_dga_score.sql
│       └── netflow_overview.sql
└── docs/
    ├── collector.md
    ├── maxmind.md
    ├── mikrotik.md
    ├── openobserve.md
    └── troubleshooting.md
```

## Quick start

```bash
git clone https://github.com/pi4-dev/mikrotik-openobserve-stack.git
cd mikrotik-openobserve-stack
cp .env.example .env
mkdir -p data/openobserve
```

Edit `.env`:

```dotenv
OPENOBSERVE_ORG=default
OPENOBSERVE_USER=root@example.com
OPENOBSERVE_PASSWORD=change-me-now
```

Then:

```bash
docker compose pull
docker compose up -d
docker compose ps -a
```

Expected state:

```text
openobserve        running
goflow2            running
syslog-ng          running
goflow-pipe-init   exited (0)
```

`goflow-pipe-init` is intentionally a one-shot service that creates the GoFlow2/syslog-ng FIFO.

OpenObserve UI:

```text
http://<collector-ip>:5080
```

## MikroTik configuration

Apply [docs/mikrotik.md](docs/mikrotik.md), or edit both occurrences of `192.0.2.10` in:

```text
config/mikrotik/routeros.rsc
```

Default ports:

| Function | Protocol | Port |
|---|---|---:|
| RouterOS DNS syslog | UDP | 5514 |
| NetFlow v9 | UDP | 2055 |
| OpenObserve UI/API | TCP | 5080 |

The RouterOS DNS logging rule filters to compact query records using:

```text
topics=dns,!packet
regex="^query from "
```

## DNS pipeline

Create these OpenObserve functions from the repository:

```text
mikrotik_dns_parser
dns_filter          # optional
```

Recommended pipeline:

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

The parser adds:

```text
dns_client_ip
dns_query_id
dns_domain
dns_record_type
dns_tld
dns_public_suffix
dns_registered_domain
```

Example input:

```text
query from 10.254.249.10: #8630451 static.cloudflareinsights.com. A
```

Example parsed fields:

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

## NetFlow direction classification

Create:

```text
openobserve/functions/netflow_direction.vrl
```

The default internal prefixes are:

```text
10.0.0.0/8
192.168.0.0/16
```

Customize the `internal_nets` array when required.

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

## MaxMind GeoIP / ASN

The stack enables OpenObserve's built-in MaxMind support. OpenObserve maintains two built-in enrichment tables:

```text
maxmind_city
maxmind_asn
```

The Compose service enables MMDB download and persists the databases under the existing OpenObserve data mount:

```dotenv
ZO_MMDB_DISABLE_DOWNLOAD=false
ZO_MMDB_DATA_DIR=/data/mmdb
ZO_MMDB_UPDATE_DURATION_DAYS=30
```

On the Docker host this corresponds to:

```text
./data/openobserve/mmdb
```

Database and SHA256 URLs are configurable in `.env.example`.

See [docs/maxmind.md](docs/maxmind.md) for automatic updates, verification and manual/air-gapped operation.

## NetFlow GeoIP function

Create:

```text
openobserve/functions/netflow_geoip.vrl
```

It enriches both endpoints using `maxmind_city` and `maxmind_asn`.

Source fields:

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

Private addresses normally have no MaxMind record; failed lookups are treated as a normal condition and do not fail the event.

## Recommended NetFlow pipeline

Keep all flow classes:

```text
netflow Source
    ↓
netflow_direction
    ↓
netflow_geoip
    ↓
netflow Destination
```

Or store only Internet flows:

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

The second form performs MaxMind lookup only for flows that will be retained.

Do not leave a parallel Source → Destination bypass path in either pipeline.

## Validate MaxMind

Host filesystem:

```bash
find data/openobserve/mmdb -maxdepth 1 -type f -ls
```

Container:

```bash
docker compose exec openobserve sh -c 'ls -lah /data/mmdb'
```

OpenObserve log:

```bash
docker compose logs openobserve | grep -Ei 'mmdb|maxmind|geolite'
```

Test `netflow_geoip` with:

```json
{
  "src_addr": "10.0.0.10",
  "dst_addr": "1.1.1.1"
}
```

The destination should receive public GeoIP/ASN fields when the MMDB databases are loaded.

## Dashboard queries

Starter SQL:

- `openobserve/sql/dns_dga_score.sql` — explainable DGA heuristic, raw component metrics and final score 0–100.
- `openobserve/sql/netflow_overview.sql` — flow/byte volume, top endpoints, ports, protocols and exporter health.

The DNS DGA score combines:

- singleton-domain percentage — 35%
- low queries-per-domain ratio — 25%
- digit percentage — 15%
- average registered-domain length — 15%
- TLD diversity — 10%

## Validation

OpenObserve health:

```bash
curl -f http://127.0.0.1:5080/healthz
```

syslog-ng syntax:

```bash
docker compose exec syslog-ng syslog-ng --syntax-only
```

FIFO:

```bash
docker compose exec syslog-ng sh -c 'test -p /run/goflow2/flows.pipe && ls -l /run/goflow2/flows.pipe'
```

UDP listeners:

```bash
ss -lunp | grep -E ':5514|:2055'
```

Do not attach another long-lived reader (`cat`, `tail -f`) to the FIFO while syslog-ng is consuming it; FIFO readers compete for records.

## Important RouterOS Traffic-Flow limitation

Traffic-Flow sees traffic processed by the RouterOS CPU. Hardware-offloaded bridged traffic may bypass the CPU and therefore may not appear in NetFlow.

## Security notes

- Keep `.env` out of Git.
- Restrict UDP/5514 and UDP/2055 to known RouterOS exporters.
- Do not expose OpenObserve TCP/5080 directly to the Internet.
- Prefer dedicated ingestion credentials over the root account.
- Review retention early: DNS and unsampled flow telemetry can generate substantial volume.

## Documentation

- [Collector: GoFlow2 + syslog-ng](docs/collector.md)
- [MaxMind GeoIP/ASN](docs/maxmind.md)
- [MikroTik configuration](docs/mikrotik.md)
- [OpenObserve functions and pipelines](docs/openobserve.md)
- [Troubleshooting](docs/troubleshooting.md)

## Upstream references

- OpenObserve: https://openobserve.ai/docs/
- OpenObserve MaxMind examples: https://openobserve.ai/docs/user-guide/data-processing/enrichment-tables/enrichment-example/
- OpenObserve environment variables: https://openobserve.ai/docs/administration/configuration/environment-variables/
- syslog-ng OpenObserve destination: https://syslog-ng.github.io/admin-guide/070_Destinations/153_OpenObserve/README.html
- GoFlow2: https://github.com/netsampler/goflow2
- MikroTik RouterOS Logging: https://help.mikrotik.com/docs/spaces/ROS/pages/328094/Log
- MikroTik RouterOS Traffic-Flow: https://help.mikrotik.com/docs/spaces/ROS/pages/21102653/Traffic%2BFlow
