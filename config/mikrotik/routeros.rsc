# MikroTik RouterOS example configuration
#
# Change collectorIp before running this script.
# The stack defaults to UDP/5514 for DNS syslog and UDP/2055 for NetFlow v9.

:local collectorIp "192.0.2.10"

# -----------------------------------------------------------------------------
# DNS query logging -> syslog-ng
# -----------------------------------------------------------------------------
# dns,!packet keeps the concise DNS messages while suppressing the very verbose
# packet-level DNS trace. syslog-ng additionally selects only messages starting
# with "query from ".

/system logging action
add name=openobserve-dns \
    target=remote \
    remote=$collectorIp \
    remote-port=5514 \
    bsd-syslog=yes \
    syslog-facility=local0 \
    syslog-severity=notice

/system logging
add action=openobserve-dns topics=dns,!packet

# -----------------------------------------------------------------------------
# NetFlow v9 -> GoFlow2
# -----------------------------------------------------------------------------
# Traffic-Flow observes traffic processed by the RouterOS CPU. Hardware-offloaded
# bridged traffic might not be visible.

/ip traffic-flow
set enabled=yes \
    interfaces=all \
    active-flow-timeout=1m \
    inactive-flow-timeout=15s

/ip traffic-flow target
add dst-address=$collectorIp \
    port=2055 \
    version=9 \
    v9-template-refresh=20 \
    v9-template-timeout=1m

# Verification commands:
# /system logging action print detail where name="openobserve-dns"
# /system logging print detail where action="openobserve-dns"
# /ip traffic-flow print
# /ip traffic-flow target print detail
