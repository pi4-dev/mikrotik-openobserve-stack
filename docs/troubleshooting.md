# Troubleshooting

Work from the source toward OpenObserve. Do not debug the OpenObserve pipeline before confirming packets and raw ingestion.

## 1. Containers

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

`goflow-pipe-init` is a one-shot initializer. `exited (0)` is correct; it creates the FIFO and exits.

Inspect logs:

```bash
docker compose logs --tail=200 openobserve
docker compose logs --tail=200 syslog-ng
docker compose logs --tail=200 goflow2
docker compose logs --tail=50 goflow-pipe-init
```

## 2. OpenObserve health

```bash
curl -f http://127.0.0.1:5080/healthz
```

Expected:

```json
{"status":"ok"}
```

If the UI starts but syslog-ng cannot ingest data, verify the credentials in `.env` and compare them with the credentials shown by OpenObserve's ingestion page.

## 3. Check listening UDP ports

```bash
ss -lunp | grep -E ':5514|:2055'
```

Expected listeners:

```text
UDP/5514 -> syslog-ng
UDP/2055 -> goflow2
```

## 4. Validate syslog-ng syntax

```bash
docker compose exec syslog-ng syslog-ng --syntax-only
```

The stack defaults to syslog-ng 4.12.0 and uses its native `openobserve-log()` destination.

## 5. Verify the GoFlow2 FIFO

```bash
docker compose exec syslog-ng sh -c 'ls -l /run/goflow2/flows.pipe && test -p /run/goflow2/flows.pipe'
```

Do **not** use `cat`, `tail -f`, or another persistent reader on the FIFO while syslog-ng is running. Multiple FIFO readers compete for bytes and a diagnostic reader can steal NetFlow records from syslog-ng.

If the FIFO is missing or is a regular file:

```bash
docker compose down
docker compose run --rm goflow-pipe-init
docker compose up -d
```

## 6. DNS: verify packets reach the host

```bash
sudo tcpdump -ni any udp port 5514
```

Generate a DNS request through the MikroTik resolver.

If packets do not arrive:

1. Check `/system logging action` on RouterOS.
2. Check `remote-port=<collector-ip>:5514`.
3. Check routing/VLAN/firewall between router and collector.
4. Verify the RouterOS logging rule uses the expected remote action.

## 7. DNS: verify RouterOS logs the query

```routeros
/log print where topics~"dns"
```

Expected compact message:

```text
query from 10.254.249.10: #8630451 static.cloudflareinsights.com. A
```

The repository uses:

```routeros
topics=dns,!packet regex="^query from "
```

so verbose DNS packet tracing is not exported.

## 8. DNS arrives at syslog-ng but not OpenObserve

```bash
docker compose logs -f syslog-ng
```

The defensive syslog-ng filter expects:

```text
PROGRAM = dns
LEVEL   = notice
MESSAGE starts with "query from "
```

If RouterOS produces different metadata, temporarily loosen `f_mikrotik_dns_query` in `config/syslog-ng/syslog-ng.conf` and restart syslog-ng.

## 9. DNS stream exists but parser fields are absent

The real-time pipeline affects new records only.

Verify:

1. `dnslog` is the pipeline source.
2. `mikrotik_dns_parser` is attached.
3. destination points back to `dnslog`.
4. no bypass path connects source directly to destination.
5. a new DNS query was generated after saving the pipeline.

Test input:

```json
{
  "message": "query from 10.254.249.10: #8630451 static.cloudflareinsights.com. A"
}
```

## 10. DNS filtering appears ineffective

`dns_filter.vrl` only sets:

```text
dns_filter_drop=true
```

The following Condition must pass only:

```text
dns_filter_drop = false
```

Also remove any parallel bypass route.

## 11. NetFlow: verify UDP packets

```bash
sudo tcpdump -ni any udp port 2055
```

On RouterOS:

```routeros
/ip traffic-flow print
/ip traffic-flow target print detail
```

Check that Traffic-Flow is enabled and points to the Docker host on UDP/2055.

## 12. NetFlow packets arrive but `netflow` is empty

1. Confirm GoFlow2 is running:

```bash
docker compose ps goflow2
```

2. Check GoFlow2 logs:

```bash
docker compose logs --tail=200 goflow2
```

3. Confirm FIFO:

```bash
docker compose exec syslog-ng test -p /run/goflow2/flows.pipe
```

4. Check syslog-ng JSON parsing/authentication errors:

```bash
docker compose logs --tail=200 syslog-ng
```

5. Search a recent time range in OpenObserve.

There is intentionally no `flows.log` file.

## 13. GoFlow2 appears blocked during startup

Opening a FIFO writer can wait until a reader exists. A brief wait while syslog-ng starts is normal.

If it remains blocked:

```bash
docker compose ps -a
docker compose logs syslog-ng goflow2
```

Verify syslog-ng loaded `s_goflow2_pipe` and the FIFO exists.

## 14. `direction` / `internet_flow` fields are absent

Verify the NetFlow OpenObserve pipeline contains:

```text
netflow Source
    ↓
netflow_direction
```

and that you generated **new** flows after saving the pipeline.

Test `netflow_direction` with:

```json
{
  "src_addr": "10.0.0.10",
  "dst_addr": "1.1.1.1"
}
```

Expected:

```json
{
  "internet_flow": true,
  "direction": "outbound"
}
```

If classification is wrong, edit `internal_nets` in `openobserve/functions/netflow_direction.vrl` to match your environment.

## 15. MaxMind MMDB files are missing

Verify `.env` contains:

```dotenv
ZO_MMDB_DISABLE_DOWNLOAD=false
ZO_MMDB_DATA_DIR=/data/mmdb
```

Check the persistent directory:

```bash
find data/openobserve/mmdb -maxdepth 1 -type f -ls
```

Check inside OpenObserve:

```bash
docker compose exec openobserve sh -c 'ls -lah /data/mmdb'
```

Check logs:

```bash
docker compose logs openobserve | grep -Ei 'mmdb|maxmind|geolite'
```

If the directory stays empty, verify DNS and HTTPS egress to the MMDB and SHA256 URLs configured in `.env`.

For manually managed/air-gapped mode see `docs/maxmind.md`.

## 16. `netflow_geoip` compiles but adds no fields

First test with a known public IP rather than RFC1918 addresses:

```json
{
  "src_addr": "10.0.0.10",
  "dst_addr": "1.1.1.1"
}
```

The private source normally has no MaxMind result. The public destination should receive fields such as:

```text
dst_geo_country_code
dst_geo_latitude
dst_geo_longitude
dst_geo_asn
dst_geo_as_org
```

If public IPs also return no fields:

1. verify MMDB files exist,
2. verify `netflow_geoip` is after `netflow_direction`/Condition in the pipeline,
3. generate new records after saving the pipeline,
4. inspect OpenObserve logs.

## 17. GeoIP works for one direction only

Check the raw event actually contains both:

```text
src_addr
dst_addr
```

Then test the function directly with explicit public values for each side.

A failed lookup on one endpoint does not prevent enrichment of the other endpoint.

## 18. NetFlow misses expected LAN traffic

This can be normal for hardware-offloaded traffic. MikroTik Traffic-Flow reports traffic processed by the router CPU; hardware-offloaded bridged traffic can be absent.

Also review the configured Traffic-Flow interface list.

## 19. Field names differ from example dashboards

NetFlow v9 is template-based. Exact GoFlow2 fields can vary.

Inspect a recent event:

```sql
SELECT *
FROM "netflow"
ORDER BY _timestamp DESC
LIMIT 1;
```

Adapt `openobserve/sql/netflow_overview.sql` if required.

## 20. OpenObserve disk usage grows quickly

DNS and unsampled flow export can create substantial volume.

Tune in this order:

1. filter uninteresting DNS records,
2. optionally keep only `internet_flow=true`,
3. set stream retention,
4. restrict Traffic-Flow interfaces,
5. consider RouterOS packet sampling on high-volume links,
6. use summary/pre-aggregated streams for expensive long-range dashboards.

## 21. Reset test data

For a disposable test deployment only:

```bash
docker compose down
rm -rf data/openobserve/*
docker compose up -d
```

This removes OpenObserve data, MMDB files, users, streams, functions, pipelines and dashboards. Do not use it on a deployment containing data you need.
