-- OpenObserve / GoFlow2 starter dashboard queries.
-- Copy individual sections into separate dashboard panels.
-- Queries 8+ require netflow_direction and netflow_geoip in the NetFlow pipeline.

-- ---------------------------------------------------------------------------
-- 1. Flow records over time (Line)
-- ---------------------------------------------------------------------------
SELECT
    histogram(_timestamp) AS x_axis_1,
    COUNT(*) AS y_axis_1
FROM "netflow"
GROUP BY x_axis_1
ORDER BY x_axis_1 ASC;

-- ---------------------------------------------------------------------------
-- 2. Bytes over time (Line/Area)
-- ---------------------------------------------------------------------------
SELECT
    histogram(_timestamp) AS x_axis_1,
    SUM(bytes) AS y_axis_1
FROM "netflow"
GROUP BY x_axis_1
ORDER BY x_axis_1 ASC;

-- ---------------------------------------------------------------------------
-- 3. Top source addresses by bytes (Horizontal Bar/Table)
-- ---------------------------------------------------------------------------
SELECT
    src_addr AS x_axis_1,
    SUM(bytes) AS y_axis_1,
    SUM(packets) AS packets,
    COUNT(*) AS flows
FROM "netflow"
WHERE src_addr IS NOT NULL
GROUP BY src_addr
ORDER BY y_axis_1 DESC
LIMIT 20;

-- ---------------------------------------------------------------------------
-- 4. Top destination addresses by bytes (Horizontal Bar/Table)
-- ---------------------------------------------------------------------------
SELECT
    dst_addr AS x_axis_1,
    SUM(bytes) AS y_axis_1,
    SUM(packets) AS packets,
    COUNT(*) AS flows
FROM "netflow"
WHERE dst_addr IS NOT NULL
GROUP BY dst_addr
ORDER BY y_axis_1 DESC
LIMIT 20;

-- ---------------------------------------------------------------------------
-- 5. Top destination ports (Bar/Table)
-- ---------------------------------------------------------------------------
SELECT
    dst_port AS x_axis_1,
    SUM(bytes) AS y_axis_1,
    COUNT(*) AS flows
FROM "netflow"
WHERE dst_port IS NOT NULL
GROUP BY dst_port
ORDER BY y_axis_1 DESC
LIMIT 20;

-- ---------------------------------------------------------------------------
-- 6. Protocol distribution (Donut)
-- ---------------------------------------------------------------------------
SELECT
    proto AS x_axis_1,
    COUNT(*) AS y_axis_1,
    SUM(bytes) AS bytes
FROM "netflow"
WHERE proto IS NOT NULL
GROUP BY proto
ORDER BY y_axis_1 DESC;

-- ---------------------------------------------------------------------------
-- 7. Exporter/sampler health (Table)
-- ---------------------------------------------------------------------------
SELECT
    sampler_address,
    COUNT(*) AS flows,
    SUM(bytes) AS bytes,
    MAX(_timestamp) AS last_record
FROM "netflow"
WHERE sampler_address IS NOT NULL
GROUP BY sampler_address
ORDER BY last_record DESC;

-- ---------------------------------------------------------------------------
-- 8. Direction distribution (Donut)
-- Requires netflow_direction.vrl
-- ---------------------------------------------------------------------------
SELECT
    direction AS x_axis_1,
    COUNT(*) AS y_axis_1,
    SUM(bytes) AS bytes
FROM "netflow"
WHERE direction IS NOT NULL
GROUP BY direction
ORDER BY y_axis_1 DESC;

-- ---------------------------------------------------------------------------
-- 9. Internet bytes over time by direction (Line)
-- Requires netflow_direction.vrl
-- ---------------------------------------------------------------------------
SELECT
    histogram(_timestamp) AS x_axis_1,
    direction AS breakdown_1,
    SUM(bytes) AS y_axis_1
FROM "netflow"
WHERE internet_flow = true
  AND direction IN ('inbound', 'outbound')
GROUP BY x_axis_1, direction
ORDER BY x_axis_1 ASC;

-- ---------------------------------------------------------------------------
-- 10. Top outbound destination countries by bytes (Bar/Table)
-- Requires netflow_geoip.vrl
-- ---------------------------------------------------------------------------
SELECT
    dst_geo_country_code AS x_axis_1,
    SUM(bytes) AS y_axis_1,
    COUNT(*) AS flows
FROM "netflow"
WHERE direction = 'outbound'
  AND dst_geo_country_code IS NOT NULL
GROUP BY dst_geo_country_code
ORDER BY y_axis_1 DESC
LIMIT 30;

-- ---------------------------------------------------------------------------
-- 11. Top outbound destination ASNs by bytes (Table)
-- Requires netflow_geoip.vrl
-- ---------------------------------------------------------------------------
SELECT
    dst_geo_asn,
    dst_geo_as_org,
    SUM(bytes) AS bytes,
    SUM(packets) AS packets,
    COUNT(*) AS flows
FROM "netflow"
WHERE direction = 'outbound'
  AND dst_geo_asn IS NOT NULL
GROUP BY dst_geo_asn, dst_geo_as_org
ORDER BY bytes DESC
LIMIT 30;

-- ---------------------------------------------------------------------------
-- 12. Top inbound source countries by bytes (Bar/Table)
-- Requires netflow_geoip.vrl
-- ---------------------------------------------------------------------------
SELECT
    src_geo_country_code AS x_axis_1,
    SUM(bytes) AS y_axis_1,
    COUNT(*) AS flows
FROM "netflow"
WHERE direction = 'inbound'
  AND src_geo_country_code IS NOT NULL
GROUP BY src_geo_country_code
ORDER BY y_axis_1 DESC
LIMIT 30;

-- ---------------------------------------------------------------------------
-- 13. Top inbound source ASNs by bytes (Table)
-- Requires netflow_geoip.vrl
-- ---------------------------------------------------------------------------
SELECT
    src_geo_asn,
    src_geo_as_org,
    SUM(bytes) AS bytes,
    SUM(packets) AS packets,
    COUNT(*) AS flows
FROM "netflow"
WHERE direction = 'inbound'
  AND src_geo_asn IS NOT NULL
GROUP BY src_geo_asn, src_geo_as_org
ORDER BY bytes DESC
LIMIT 30;
