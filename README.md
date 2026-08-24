# MikroTik → OpenObserve DNS + NetFlow stack

A small Docker Compose stack for collecting two telemetry streams from MikroTik RouterOS:

- **DNS queries**: RouterOS remote syslog → syslog-ng → OpenObserve stream `dnslog`
- **NetFlow v9**: RouterOS Traffic-Flow → GoFlow2 → JSON file → syslog-ng → OpenObserve stream `netflow`

The design intentionally keeps OpenObserve's deprecated built-in syslog listener out of the data path. syslog-ng receives RouterOS syslog and uses its native `openobserve-log()` destination. GoFlow2 receives NetFlow v9 on UDP/2055 and emits newline-delimited JSON which the same syslog-ng instance forwards to OpenObserve.

## Architecture

```text
                         +-----------------------+
                         |       MikroTik        |
                         |                       |
DNS logging ------------+--> UDP/5514           |
Traffic-Flow v9 ---------+--> UDP/2055           |
                         +-----------+-----------+
                                     |
                 +-------------------+-------------------+
                 |                                       |
                 v                                       v
        +----------------+                      +----------------+
        |   syslog-ng    |                      |    GoFlow2     |
        | UDP/5514       |                      | UDP/2055       |
        +-------+--------+                      +-------+--------+
                |                                       |
                |                         JSON lines    |
                |                              to shared volume
                |                                       |
                |                 +---------------------+
                |                 |
                v                 v
             +------------------------+
             |       syslog-ng        |
             | OpenObserve JSON API   |
             +-----------+------------+
                         |
              +----------+----------+
              |                     |
              v                     v
      OpenObserve:dnslog     OpenObserve:netflow
```

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
    ├── mikrotik.md
    ├── openobserve.md
    └── troubleshooting.md
```

## Quick start

### 1. Prepare the environment

```bash
git clone https://github.com/pi4-dev/mikrotik-openobserve-stack.git
cd mikrotik-openobserve-stack
cp .env.example .env
mkdir -p data/openobserve
```

Edit `.env` and set at least:

```dotenv
OPENOBSERVE_USER=root@example.com
OPENOBSERVE_PASSWORD=change-me-now
OPENOBSERVE_ORG=default
```

`.env` is ignored by Git and must never be committed.

For an existing OpenObserve installation, use dedicated ingestion credentials from the OpenObserve ingestion page instead of the root account when possible.

### 2. Start the stack

```bash
docker compose pull
docker compose up -d
```

Check containers:

```bash
docker compose ps
docker compose logs -f openobserve
docker compose logs -f syslog-ng
docker compose logs -f goflow2
```

OpenObserve UI:

```text
http://<collector-ip>:5080
```

### 3. Configure RouterOS

Edit `config/mikrotik/routeros.rsc` and change the collector IP, or apply the commands manually as described in [docs/mikrotik.md](docs/mikrotik.md).

The default ports used by this repository are:

| Function | Protocol | Port |
|---|---|---:|
| RouterOS remote syslog | UDP | 5514 |
| NetFlow v9 / IPFIX collector | UDP | 2055 |
| OpenObserve UI/API | TCP | 5080 |

### 4. Create the DNS parser pipeline

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

The optional `dns_filter.vrl` marks unwanted records with `dns_filter_drop=true`. A following Condition node can discard them.

See [docs/openobserve.md](docs/openobserve.md) for the complete procedure.

## DNS event example

RouterOS generates a compact DNS message such as:

```text
query from 10.254.249.10: #8630451 static.cloudflareinsights.com. A
```

After the OpenObserve parser:

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

## NetFlow event example

GoFlow2 receives RouterOS NetFlow v9 and produces JSON containing fields such as:

```json
{
  "type": "NETFLOW_V9",
  "sampler_address": "192.0.2.1",
  "src_addr": "10.0.0.10",
  "dst_addr": "1.1.1.1",
  "src_port": 54321,
  "dst_port": 443,
  "proto": "TCP",
  "bytes": 4271,
  "packets": 17
}
```

These records are stored in the `netflow` stream.

## Dashboard queries

Two starter SQL files are included:

- `openobserve/sql/dns_dga_score.sql` — client-level DGA heuristic with all component metrics and a 0–100 score.
- `openobserve/sql/netflow_overview.sql` — starter NetFlow aggregations.

The DGA score is a heuristic/ranking signal, not a malware verdict. It combines domain singleton ratio, queries per domain, digit ratio, average registered-domain length and TLD diversity.

## Important RouterOS limitation

RouterOS Traffic-Flow sees traffic processed by the router CPU. Hardware-offloaded bridged traffic does not necessarily appear in Traffic-Flow. Design dashboards with that limitation in mind.

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

### UDP listeners

```bash
ss -lunp | grep -E ':5514|:2055'
```

### GoFlow2 input

After enabling Traffic-Flow on RouterOS:

```bash
docker compose logs -f goflow2
```

and verify that the `netflow` stream receives records in OpenObserve.

## Security notes

- Keep `.env` out of Git.
- Restrict UDP/5514 and UDP/2055 at the collector firewall to RouterOS exporter addresses.
- Do not expose OpenObserve TCP/5080 directly to the Internet.
- Prefer dedicated OpenObserve ingestion credentials over the root account.
- If OpenObserve is accessed across an untrusted network, put HTTPS in front of it or use a trusted internal TLS path.

## References

- OpenObserve self-hosted Docker and JSON ingestion documentation
- syslog-ng `openobserve-log()` destination documentation
- GoFlow2 project documentation
- MikroTik RouterOS Logging and Traffic-Flow documentation
