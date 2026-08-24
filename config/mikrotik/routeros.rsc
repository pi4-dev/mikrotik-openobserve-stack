# MikroTik RouterOS example configuration
#
# Replace 192.0.2.10 with the Docker host / collector address reachable from
# the router before importing this file.
#
# The stack defaults to:
#   DNS syslog: UDP/5514
#   NetFlow v9: UDP/2055

# -----------------------------------------------------------------------------
# DNS query logging -> syslog-ng
# -----------------------------------------------------------------------------
# Current RouterOS uses remote-port=IP:PORT and remote-log-format=syslog.
# The regex is evaluated by RouterOS before the remote action, so only compact
# "query from ..." DNS events are exported. !packet additionally excludes the
# verbose packet-level DNS trace.

/system logging action add name=openobserve-dns target=remote remote-port=192.0.2.10:5514 remote-log-format=syslog syslog-facility=local0 syslog-severity=notice
/system logging add action=openobserve-dns topics=dns,!packet regex="^query from "

# -----------------------------------------------------------------------------
# NetFlow v9 -> GoFlow2
# -----------------------------------------------------------------------------
# Traffic-Flow observes traffic processed by the RouterOS CPU. Hardware-offloaded
# bridged traffic might not be visible.

/ip traffic-flow set enabled=yes interfaces=all active-flow-timeout=1m inactive-flow-timeout=15s
/ip traffic-flow target add dst-address=192.0.2.10 port=2055 version=9 v9-template-refresh=20 v9-template-timeout=1m

# Verification commands:
# /system logging action print detail where name="openobserve-dns"
# /system logging print detail where action="openobserve-dns"
# /ip traffic-flow print
# /ip traffic-flow target print detail
