# MikroTik → OpenObserve DNS + NetFlow stack

A reproducible Docker Compose stack for collecting two telemetry streams from MikroTik RouterOS:

- **DNS queries**: RouterOS remote syslog → syslog-ng → OpenObserve stream `dnslog`
- **NetFlow v9**: RouterOS Traffic-Flow → GoFlow2 → FIFO → syslog-ng → OpenObserve stream `netflow`

The design intentionally keeps OpenObserve's deprecated built-in syslog listener out of the data path. syslog-ng receives RouterOS syslog and forwards structured records with its native `openobserve-log()` destination. GoFlow2 receives NetFlow v9 on UDP/2055 and emits newline-delimited JSON into a named pipe read by syslog-ng.

A FIFO is used instead of an intermediate flow log file so there is no continuously growing `flows.log` to rotate or clean up.

## Architecture

```text
                      +-----------------------+
                      |       MikroTik        |
                      |                       |
DNS logging ----------+--> UDP/5514           |
Traffic-Flow v9 ------+--> UDP/2055           |
                      +-----------+-----------+
                                  |
                 +----------------+----------------+
                 |                                 |
                 v                                 v
        +----------------+                +----------------+
        |   syslog-ng    |                |    GoFlow2     |
        | UDP/5514       |                | UDP/2055       |
        +-------+--------+                +-------+--------+
                |                                 |
                |                          JSON lines
                |                                 |
                |                                 v
                |                         +---------------+
                |                         | shared FIFO   |
                |                         | flows.pipe    |
                |                         +-------+-------+
                |                                 |
                +----------------+----------------+
                                 |
                                 v
                      +-----------------------+
                      |      syslog-ng        |
                      | openobserve-log()     |
                      +-----------+-----------+
                                  |
                         OpenObserve JSON API
                                  |
                      +-----------+-----------+
                      |                       |
                      v                       v
              stream: dnslog          stream: netflow
```

## Components

Default image versions/tags are pinned in `.env.example` so upgrades are explicit:

| Component | Default |
|---|---|
| OpenObserve | `v0.92.2` |
| GoFlow2 | `v2` branch image `2d10ea3` |
| syslog-ng | `4.12.0` |
| Alpine init image | `3.23` |

GoFlow2's Docker registry does not publish release-number tags such as `v2.2.6`; this repository therefore pins a published multi-arch commit image from its maintained `v2` branch rather than using mutable `latest`.

Override versions/tags in `.env` only when intentionally upgrading.

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
│   │   └── dns_filter.vrl
│   └── sql/
│       ├── dns_dga_score.sql
│       └── netflow_overview.sql
└── docs/
    ├── collector.md
    ├── mikrotik.md
    ├── openobserve.md
    └── troubleshooting.md
```

## Quick start

### 1. Clone and prepare

```bash
git clone https://github.com/pi4-dev/mikrotik-openobserve-stack.git
cd mikrotik-openobserve-stack
cp .env.example .env
mkdir -p data/openobserve
```

Edit `.env` and set at least:

```dotenv
OPENOBSERVE_ORG=default
OPENOBSERVE_USER=root@example.com
OPENOBSERVE_PASSWORD=change-me-now
```

`.env` is ignored by Git and must never be committed.

For an existing OpenObserve deployment, use dedicated ingestion credentials from the OpenObserve ingestion page instead of the root account when possible.

### 2. Start the stack

```bash
docker compose pull
docker compose up -d
```

Check status:

```bash
docker compose ps -a
```

Expected state:

```text
openobserve        running
goflow2            running
syslog-ng          running
goflow-pipe-init   exited (0)
```

`goflow-pipe-init` is intentionally a one-shot container. It creates `/run/goflow2/flows.pipe`, fixes its permissions and exits successfully.

Useful logs:

```bash
docker compose logs -f openobserve
docker compose logs -f syslog-ng
docker compose logs -f goflow2
```

OpenObserve UI:

```text
http://<collector-ip>:5080
```

### 3. Configure RouterOS

Apply the commands from [docs/mikrotik.md](docs/mikrotik.md), or edit both occurrences of `192.0.2.10` in:

```text
config/mikrotik/routeros.rsc
```

before importing it.

Default ports:

| Function | Protocol | Port |
|---|---|---:|
| RouterOS remote DNS syslog | UDP | 5514 |
| NetFlow v9 collector | UDP | 2055 |
| OpenObserve UI/API | TCP | 5080 |

The RouterOS DNS logging rule uses both `topics=dns,!packet` and `regex="^query from "`, so only compact DNS query events are sent to syslog-ng.

### 4. Create the OpenObserve DNS parser pipeline

In OpenObserve create a real-time pipeline for stream `dnslog`:

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

Paste the function from:

```text
openobserve/functions/mikrotik_dns_parser.vrl
```

It adds:

```text
dns_client_ip
dns_query_id
dns_domain
dns_record_type
dns_tld
dns_public_suffix
dns_registered_domain
```

The optional `dns_filter.vrl` marks unwanted records with `dns_filter_drop=true`. A following Condition node must pass only `dns_filter_drop=false` if you want those events discarded.

Do not leave a parallel source-to-destination path that bypasses the filter.

See [docs/openobserve.md](docs/openobserve.md) for the full procedure.

## DNS event example

RouterOS generates:

```text
query from 10.254.249.10: #8630451 static.cloudflareinsights.com. A
```

After the parser:

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

`dns_registered_domain` is Public-Suffix-List aware, so multi-label public suffixes such as `co.uk` are handled correctly.

## NetFlow processing

RouterOS exports NetFlow v9 to:

```text
<collector-ip>:2055/udp
```

GoFlow2 decodes the flow templates and writes newline-delimited JSON to:

```text
/run/goflow2/flows.pipe
```

The pipe lives in the shared `goflow-pipe` Docker volume. syslog-ng reads it with a native `pipe()` source, parses each JSON line with `json-parser()` and sends the structured fields to OpenObserve stream `netflow`.

No intermediate flow file is stored on disk by this handoff.

Typical decoded fields include:

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
```

Actual fields depend on the NetFlow v9 templates exported by RouterOS.

For details of the GoFlow2/FIFO/syslog-ng handoff, batching and failure semantics see [docs/collector.md](docs/collector.md).

## Dashboard queries

Starter SQL files:

- `openobserve/sql/dns_dga_score.sql` — explainable client-level DGA heuristic with raw metrics, normalized component scores and a final 0–100 score.
- `openobserve/sql/netflow_overview.sql` — traffic volume, top sources/destinations, ports, protocols and exporter health.

The DGA score is a heuristic/ranking signal, not a malware verdict. It combines:

- singleton-domain percentage — 35%
- low queries-per-domain ratio — 25%
- digit percentage in registered domains — 15%
- average registered-domain length — 15%
- TLD diversity — 10%

The SQL file also contains suggested table-coloring thresholds.

## Validation

### OpenObserve

```bash
curl -f http://127.0.0.1:5080/healthz
```

Expected:

```json
{"status":"ok"}
```

### syslog-ng configuration

```bash
docker compose exec syslog-ng syslog-ng --syntax-only
```

### FIFO

```bash
docker compose exec syslog-ng sh -c 'ls -l /run/goflow2/flows.pipe && test -p /run/goflow2/flows.pipe'
```

Do **not** run `cat`, `tail -f`, or another long-lived reader against the FIFO while syslog-ng is consuming it. A FIFO distributes bytes among readers; a diagnostic reader could steal flow records from syslog-ng.

### UDP listeners

```bash
ss -lunp | grep -E ':5514|:2055'
```

### Packet-level verification

```bash
sudo tcpdump -ni any udp port 5514
sudo tcpdump -ni any udp port 2055
```

See [docs/troubleshooting.md](docs/troubleshooting.md) for a full source-to-destination runbook.

## Important RouterOS Traffic-Flow limitation

Traffic-Flow sees traffic processed by the RouterOS CPU. Hardware-offloaded bridged traffic may bypass the CPU and therefore may not appear in the exported flow stream.

## Security notes

- Keep `.env` out of Git.
- Restrict UDP/5514 and UDP/2055 at the collector firewall to known RouterOS exporter addresses.
- Do not expose OpenObserve TCP/5080 directly to the Internet.
- Prefer dedicated OpenObserve ingestion credentials over the root account.
- Put HTTPS in front of OpenObserve when crossing an untrusted network.
- Review retention early: DNS queries and unsampled flow telemetry can generate substantial data volume.

## Documentation

- [Collector: GoFlow2 + syslog-ng](docs/collector.md)
- [MikroTik configuration](docs/mikrotik.md)
- [OpenObserve functions, pipeline and streams](docs/openobserve.md)
- [Troubleshooting runbook](docs/troubleshooting.md)

## Upstream references

- OpenObserve: https://openobserve.ai/docs/
- syslog-ng OpenObserve destination: https://syslog-ng.github.io/admin-guide/070_Destinations/153_OpenObserve/README.html
- GoFlow2: https://github.com/netsampler/goflow2
- MikroTik RouterOS Logging: https://help.mikrotik.com/docs/spaces/ROS/pages/328094/Log
- MikroTik RouterOS Traffic-Flow: https://help.mikrotik.com/docs/spaces/ROS/pages/21102653/Traffic%2BFlow
