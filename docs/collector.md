# Collector layer: GoFlow2 + syslog-ng

This document describes the collector side of the stack between MikroTik and OpenObserve.

## Responsibilities

The collector deliberately separates protocol decoding from storage:

| Component | Responsibility |
|---|---|
| syslog-ng | receive RouterOS DNS syslog, select DNS query events, forward records to OpenObserve |
| GoFlow2 | receive and decode RouterOS NetFlow v9 |
| FIFO `flows.pipe` | transient GoFlow2 → syslog-ng handoff, no flow history stored here |
| OpenObserve | index, retain, query and visualize DNS/NetFlow records |

## DNS path

```text
MikroTik
  UDP/5514 syslog
      ↓
syslog-ng
  f_mikrotik_dns_query
      ↓
openobserve-log()
      ↓
OpenObserve / dnslog
```

RouterOS already exports only messages that match:

```text
^query from 
```

syslog-ng intentionally repeats that check and additionally expects:

```text
PROGRAM = dns
LEVEL   = notice
```

The destination constructs explicit lowercase OpenObserve fields:

```text
host
program
priority
facility
message
source_ip
_timestamp
```

`message` is then parsed by the OpenObserve VRL function `mikrotik_dns_parser`.

## NetFlow path

```text
MikroTik Traffic-Flow
      |
      | NetFlow v9 / UDP 2055
      v
   GoFlow2
      |
      | newline-delimited JSON
      v
/run/goflow2/flows.pipe
      |
      v
   syslog-ng
   json-parser()
      |
      v
openobserve-log()
      |
      v
OpenObserve / netflow
```

## Why a FIFO instead of a file

A regular GoFlow2 output file would continuously grow unless a separate rotation/cleanup mechanism were added.

The stack therefore creates a POSIX named pipe:

```text
/run/goflow2/flows.pipe
```

The pipe carries records only while both producer and consumer are running:

- GoFlow2 writes JSON lines.
- syslog-ng reads those lines immediately.
- no historical NetFlow copy is retained in the FIFO volume.
- OpenObserve is the durable storage layer.

This also means that collector backpressure matters: syslog-ng/OpenObserve problems can eventually block the GoFlow2 writer instead of silently filling a disk with an unbounded intermediate file.

## FIFO initializer

The Compose service:

```text
goflow-pipe-init
```

is a one-shot Alpine container. It:

1. ensures `/run/goflow2/flows.pipe` is a FIFO,
2. removes the path only if it exists as the wrong file type,
3. creates the FIFO when missing,
4. sets mode `0666`,
5. exits with code 0.

Expected Docker state after startup:

```text
goflow-pipe-init   exited (0)
```

Both GoFlow2 and syslog-ng depend on successful completion of this initializer.

## GoFlow2 configuration

Compose starts GoFlow2 with:

```text
-listen netflow://:2055
-transport.file /run/goflow2/flows.pipe
```

The first option creates the NetFlow listener. The second uses GoFlow2's file transport against the FIFO path.

The default GoFlow2 formatter emits structured JSON records. The exact fields depend on the NetFlow v9 templates exported by RouterOS.

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
```

Do not assume every exporter/template combination provides every field.

## syslog-ng NetFlow source

The syslog-ng source is:

```conf
source s_goflow2_pipe {
    pipe(
        "/run/goflow2/flows.pipe"
        flags(no-parse)
    );
};
```

`flags(no-parse)` is important: the source is JSON, not syslog.

The next parser converts JSON keys into structured name-value pairs:

```conf
parser p_goflow2_json {
    json-parser(prefix(""));
};
```

The OpenObserve destination then uses all parsed name-value pairs:

```conf
record("--scope nv-pairs --pair collector=\"goflow2\"")
```

and adds:

```text
collector = goflow2
```

before sending the batch to stream `netflow`.

## OpenObserve destination

Both DNS and NetFlow paths use syslog-ng's native:

```text
openobserve-log()
```

The destination uses the Docker service hostname:

```text
http://openobserve:5080
```

and credentials supplied through Compose environment variables:

```text
OPENOBSERVE_ORG
OPENOBSERVE_USER
OPENOBSERVE_PASSWORD
```

The DNS and NetFlow destinations differ only in the target stream and record mapping.

## Batching

The repository defaults to:

### DNS

```text
workers       = 2
batch-lines   = 100
batch-timeout = 1000 ms
```

### NetFlow

```text
workers       = 2
batch-lines   = 250
batch-timeout = 1000 ms
```

These are conservative homelab defaults. Increase batching/workers only after measuring collector throughput and OpenObserve ingestion behavior.

## Startup behavior

Expected sequence:

```text
1. openobserve starts
2. goflow-pipe-init creates FIFO and exits 0
3. syslog-ng opens FIFO reader and UDP/5514 listener
4. GoFlow2 opens FIFO writer and UDP/2055 listener
5. telemetry begins flowing
```

GoFlow2 may briefly wait while opening its FIFO writer until syslog-ng has opened the reader. This is normal POSIX FIFO behavior.

## Validation

Check container state:

```bash
docker compose ps -a
```

Validate syslog-ng syntax:

```bash
docker compose exec syslog-ng syslog-ng --syntax-only
```

Validate FIFO type:

```bash
docker compose exec syslog-ng sh -c 'test -p /run/goflow2/flows.pipe && ls -l /run/goflow2/flows.pipe'
```

Check network listeners:

```bash
ss -lunp | grep -E ':5514|:2055'
```

Inspect service errors:

```bash
docker compose logs --tail=200 goflow2
docker compose logs --tail=200 syslog-ng
```

Do not attach `cat`, `tail -f`, or another reader to `flows.pipe` while syslog-ng is consuming it. FIFO readers compete for data and a debug reader could take records away from syslog-ng.

## Failure semantics

### syslog-ng/OpenObserve unavailable

The FIFO path provides backpressure rather than durable buffering. If syslog-ng cannot consume records, GoFlow2 can eventually block on the pipe.

If durable collector-side buffering is required in a future deployment, replace the FIFO with a queue/broker or another explicitly bounded persistent transport rather than an unmanaged flat file.

### GoFlow2 unavailable

DNS logging remains independent and continues through syslog-ng.

### syslog-ng unavailable

Both DNS forwarding and NetFlow forwarding stop because syslog-ng is the common OpenObserve ingestion client.

## Configuration files

```text
docker-compose.yml
config/syslog-ng/syslog-ng.conf
.env.example
```

For source-side configuration see [mikrotik.md](mikrotik.md). For stream/functions/pipelines see [openobserve.md](openobserve.md).
