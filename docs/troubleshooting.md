# Troubleshooting

Work from the source toward OpenObserve. Do not debug the pipeline before confirming packets and raw ingestion.

## 1. Containers

```bash
docker compose ps
```

All three services should be running:

```text
openobserve
syslog-ng
goflow2
```

Inspect logs:

```bash
docker compose logs --tail=200 openobserve
docker compose logs --tail=200 syslog-ng
docker compose logs --tail=200 goflow2
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

The repository uses syslog-ng's native `openobserve-log()` destination, which requires syslog-ng 4.5 or newer. The official `balabit/syslog-ng:latest` image currently includes the published modules.

## 5. DNS: verify packets reach the host

```bash
sudo tcpdump -ni any udp port 5514
```

Generate a DNS request through the MikroTik resolver.

If packets do not arrive:

1. Check `/system logging action` on RouterOS.
2. Check the collector IP and UDP/5514.
3. Check routing/VLAN/firewall between router and collector.
4. Verify the RouterOS logging rule uses the expected remote action.

## 6. DNS: verify RouterOS actually logs the query

On RouterOS:

```routeros
/log print where topics~"dns"
```

Expected compact message:

```text
query from 10.254.249.10: #8630451 static.cloudflareinsights.com. A
```

If only verbose `dns,packet` entries appear, check the `dns,!packet` logging rule.

## 7. DNS arrives at syslog-ng but not OpenObserve

Check syslog-ng logs:

```bash
docker compose logs -f syslog-ng
```

The DNS path requires all of these to match:

```text
PROGRAM = dns
LEVEL   = notice
MESSAGE starts with "query from "
```

Inspect the actual syslog message if your RouterOS release or logging action produces different metadata. Temporarily loosen `f_mikrotik_dns_query` in `config/syslog-ng/syslog-ng.conf` to isolate which field differs.

After changing the configuration:

```bash
docker compose restart syslog-ng
```

## 8. DNS stream exists but parser fields are absent

The OpenObserve real-time pipeline affects new records only.

Verify:

1. `dnslog` is selected as the pipeline source.
2. `mikrotik_dns_parser` is attached after the source.
3. The destination points back to `dnslog`.
4. No bypass path connects the source directly to the destination.
5. Generate a new DNS query after saving the pipeline.

Test the VRL function with:

```json
{
  "message": "query from 10.254.249.10: #8630451 static.cloudflareinsights.com. A"
}
```

## 9. Filtering appears ineffective

`dns_filter.vrl` only sets:

```text
dns_filter_drop=true
```

The pipeline must contain a Condition after the function that passes only:

```text
dns_filter_drop = false
```

Also remove any parallel/bypass route that writes the original event directly to the destination.

## 10. NetFlow: verify UDP packets

```bash
sudo tcpdump -ni any udp port 2055
```

On RouterOS:

```routeros
/ip traffic-flow print
/ip traffic-flow target print detail
```

Check that Traffic-Flow is enabled and the target points to the Docker host.

## 11. NetFlow packets arrive but no GoFlow2 records

Inspect GoFlow2:

```bash
docker compose logs -f goflow2
```

Inspect the shared file from the syslog-ng container:

```bash
docker compose exec syslog-ng sh -c 'ls -l /var/log/goflow2 && tail -n 5 /var/log/goflow2/flows.log'
```

Each line should be valid JSON.

If the file does not exist, inspect GoFlow2 startup errors and volume permissions.

## 12. GoFlow2 file has JSON but `netflow` is empty

Check syslog-ng logs for JSON parser or OpenObserve authentication errors:

```bash
docker compose logs --tail=200 syslog-ng
```

Then confirm the OpenObserve ingestion credentials in `.env`.

## 13. NetFlow misses expected LAN traffic

This can be normal when the traffic is hardware-offloaded. MikroTik Traffic-Flow reports traffic processed by the router CPU; hardware-offloaded bridged traffic can be absent.

Also review the configured Traffic-Flow interface list and whether the observed packet path actually traverses those interfaces in software.

## 14. OpenObserve disk usage grows quickly

DNS query logging and unsampled flow export can create substantial event volume.

Tune in this order:

1. Filter uninteresting DNS records in the pipeline.
2. Set stream retention.
3. Restrict Traffic-Flow to useful interfaces.
4. Consider RouterOS packet sampling for high-volume links.
5. Use pre-aggregated/summary streams for expensive long-range dashboards when needed.

## 15. Reset test data

If this is a disposable test deployment and you want a completely clean OpenObserve instance:

```bash
docker compose down
rm -rf data/openobserve/*
docker compose up -d
```

This removes all OpenObserve local data, users, streams, functions, pipelines and dashboards. Do not use this procedure on a deployment containing data you need.
