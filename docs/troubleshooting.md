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

On the Docker host:

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

A successful `test -p` confirms that the path is a named pipe.

Do **not** use `cat`, `tail -f`, or another persistent reader on the FIFO while syslog-ng is running. Multiple FIFO readers compete for bytes, so a diagnostic reader can steal NetFlow records from syslog-ng.

If the FIFO is missing or has become a regular file:

```bash
docker compose down
docker compose run --rm goflow-pipe-init
docker compose up -d
```

Then repeat the `test -p` check.

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

## 7. DNS: verify RouterOS actually logs the query

On RouterOS:

```routeros
/log print where topics~"dns"
```

Expected compact message:

```text
query from 10.254.249.10: #8630451 static.cloudflareinsights.com. A
```

The repository configuration deliberately uses:

```routeros
topics=dns,!packet regex="^query from "
```

so verbose DNS packet tracing is not exported.

## 8. DNS arrives at syslog-ng but not OpenObserve

Check syslog-ng logs:

```bash
docker compose logs -f syslog-ng
```

The defensive syslog-ng DNS filter expects:

```text
PROGRAM = dns
LEVEL   = notice
MESSAGE starts with "query from "
```

Inspect the actual syslog metadata if your RouterOS release/action produces different values. Temporarily loosen `f_mikrotik_dns_query` in `config/syslog-ng/syslog-ng.conf` to isolate the mismatch.

After changing the configuration:

```bash
docker compose restart syslog-ng
```

## 9. DNS stream exists but parser fields are absent

The OpenObserve real-time pipeline affects new records only.

Verify:

1. `dnslog` is selected as the pipeline source.
2. `mikrotik_dns_parser` is attached after the source.
3. The destination points back to `dnslog`.
4. No bypass path connects source directly to destination.
5. Generate a new DNS query after saving the pipeline.

Test the VRL function with:

```json
{
  "message": "query from 10.254.249.10: #8630451 static.cloudflareinsights.com. A"
}
```

## 10. Filtering appears ineffective

`dns_filter.vrl` only sets:

```text
dns_filter_drop=true
```

The pipeline must contain a Condition after the function that passes only:

```text
dns_filter_drop = false
```

Also remove any parallel/bypass route that writes the original event directly to the destination.

## 11. NetFlow: verify UDP packets

```bash
sudo tcpdump -ni any udp port 2055
```

On RouterOS:

```routeros
/ip traffic-flow print
/ip traffic-flow target print detail
```

Check that Traffic-Flow is enabled and the target points to the Docker host on UDP/2055.

## 12. NetFlow packets arrive but `netflow` is empty

Work in this order:

1. Confirm GoFlow2 is running:

```bash
docker compose ps goflow2
```

2. Check GoFlow2 errors:

```bash
docker compose logs --tail=200 goflow2
```

3. Confirm the FIFO exists:

```bash
docker compose exec syslog-ng test -p /run/goflow2/flows.pipe
```

4. Check syslog-ng errors, especially JSON parsing and OpenObserve authentication:

```bash
docker compose logs --tail=200 syslog-ng
```

5. Verify the `netflow` stream in OpenObserve with a recent time range.

Because the handoff is a FIFO, there is intentionally no `flows.log` file to inspect or rotate.

## 13. GoFlow2 appears blocked during startup

Opening a FIFO for writing can wait until a reader exists. This is normal for a short period while `syslog-ng` starts and opens the same FIFO.

If it remains blocked:

```bash
docker compose ps -a
docker compose logs syslog-ng goflow2
```

Verify that syslog-ng loaded `s_goflow2_pipe` successfully and that the named pipe exists.

## 14. NetFlow misses expected LAN traffic

This can be normal when traffic is hardware-offloaded. MikroTik Traffic-Flow reports traffic processed by the router CPU; hardware-offloaded bridged traffic can be absent.

Also review the configured Traffic-Flow interface list and whether the observed packet path actually traverses those interfaces in software.

## 15. Field names differ from the example dashboards

NetFlow v9 is template-based. The exact GoFlow2 fields can vary with exporter templates and GoFlow2 version.

Inspect a recent event:

```sql
SELECT *
FROM "netflow"
ORDER BY _timestamp DESC
LIMIT 1;
```

Then adapt queries in `openobserve/sql/netflow_overview.sql` if your fields differ.

## 16. OpenObserve disk usage grows quickly

DNS query logging and unsampled flow export can create substantial event volume even though the GoFlow2/syslog-ng handoff itself does not store a flow file.

Tune in this order:

1. Filter uninteresting DNS records in the pipeline.
2. Set stream retention.
3. Restrict Traffic-Flow to useful interfaces.
4. Consider RouterOS packet sampling for high-volume links.
5. Use summary/pre-aggregated streams for expensive long-range dashboards when appropriate.

## 17. Reset test data

If this is a disposable test deployment and you want a completely clean OpenObserve instance:

```bash
docker compose down
rm -rf data/openobserve/*
docker compose up -d
```

This removes all OpenObserve local data, users, streams, functions, pipelines and dashboards. Do not use this procedure on a deployment containing data you need.
