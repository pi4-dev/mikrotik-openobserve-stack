# MikroTik RouterOS configuration

This stack expects one RouterOS device (or multiple devices) to export:

- DNS query logs over remote syslog UDP/5514
- Traffic-Flow / NetFlow v9 over UDP/2055

Replace `192.0.2.10` below with the Docker host address reachable from the router.

## 1. DNS resolver prerequisite

DNS query logging only sees requests handled by the MikroTik DNS service. Clients must actually use the router as their DNS resolver if you want their queries to appear here.

Check:

```routeros
/ip dns print
```

If LAN clients are expected to use the router resolver, `allow-remote-requests=yes` must be configured together with suitable firewall rules restricting DNS access to trusted LANs.

## 2. Configure remote DNS logging

Current RouterOS remote logging configuration uses `remote-port=IP:PORT` and `remote-log-format=syslog`.

Create a dedicated remote action:

```routeros
/system logging action add name=openobserve-dns target=remote remote-port=192.0.2.10:5514 remote-log-format=syslog syslog-facility=local0 syslog-severity=notice
```

Add the DNS logging rule:

```routeros
/system logging add action=openobserve-dns topics=dns,!packet regex="^query from "
```

The rule deliberately filters twice:

- `topics=dns,!packet` includes DNS events while excluding verbose packet-level traces.
- `regex="^query from "` makes RouterOS send only compact client query events to the collector.
- syslog-ng applies the same message-prefix check again as a defensive filter.

A useful event looks like:

```text
query from 10.254.249.10: #8630451 static.cloudflareinsights.com. A
```

Verify:

```routeros
/system logging action print detail where name="openobserve-dns"
/system logging print detail where action="openobserve-dns"
/log print where topics~"dns"
```

## 3. Configure Traffic-Flow / NetFlow v9

Enable Traffic-Flow:

```routeros
/ip traffic-flow set enabled=yes interfaces=all active-flow-timeout=1m inactive-flow-timeout=15s
```

Add the collector target:

```routeros
/ip traffic-flow target add dst-address=192.0.2.10 port=2055 version=9 v9-template-refresh=20 v9-template-timeout=1m
```

Verify:

```routeros
/ip traffic-flow print
/ip traffic-flow target print detail
```

## 4. Interface selection

`interfaces=all` is convenient for initial deployment but can create duplicate-looking perspectives when a routed flow is observed across multiple interfaces depending on the export semantics and dashboard logic.

After validating the stack, consider explicitly selecting only the interfaces relevant to your analysis.

## 5. Hardware offload limitation

RouterOS Traffic-Flow processes traffic visible to the router CPU. Hardware-offloaded bridged traffic might bypass the CPU and therefore might not be represented in the exported flow data.

Do not interpret the absence of a flow as proof that the traffic did not exist if the path can be hardware-offloaded.

## 6. Firewall on the collector

Allow only the RouterOS exporter addresses to reach:

```text
UDP/5514  syslog-ng
UDP/2055  GoFlow2
```

OpenObserve TCP/5080 should remain restricted to trusted management networks or be published through a secured reverse proxy.

## 7. Multiple routers

The same syslog-ng and GoFlow2 instances can receive data from multiple MikroTik devices.

For DNS records, the syslog `host` and `source_ip` fields identify the router that generated the event while `dns_client_ip` identifies the LAN client that made the DNS request.

For NetFlow records, GoFlow2 exposes the exporter/sampler address in `sampler_address` when supplied by the decoded flow metadata.

## 8. Full example script

A directly importable version is available in:

```text
config/mikrotik/routeros.rsc
```

Replace both occurrences of `192.0.2.10` before importing it.

## References

- RouterOS logging: https://help.mikrotik.com/docs/spaces/ROS/pages/328094/Log
- RouterOS Traffic-Flow: https://help.mikrotik.com/docs/spaces/ROS/pages/21102653/Traffic%2BFlow
- RouterOS DNS: https://help.mikrotik.com/docs/spaces/ROS/pages/37748767/DNS
