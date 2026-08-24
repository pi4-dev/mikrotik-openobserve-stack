# MaxMind GeoIP / ASN integration

OpenObserve provides two built-in MaxMind enrichment tables used by this stack:

```text
maxmind_city
maxmind_asn
```

The NetFlow enrichment function is:

```text
openobserve/functions/netflow_geoip.vrl
```

No CSV enrichment-table upload is required for these built-in tables.

## Automatic MMDB management

OpenObserve disables MMDB auto-download by default. This repository enables it in `docker-compose.yml` and `.env.example`:

```dotenv
ZO_MMDB_DISABLE_DOWNLOAD=false
ZO_MMDB_DATA_DIR=/data/mmdb
ZO_MMDB_UPDATE_DURATION_DAYS=30
```

The OpenObserve container mounts:

```text
./data/openobserve:/data
```

so the MMDB files are persisted on the Docker host under:

```text
./data/openobserve/mmdb
```

The City/ASN database URLs and their SHA256 URLs are also exposed in `.env.example`. Override them there when using an internal mirror or another trusted MMDB source.

## Verify MMDB availability

On the Docker host:

```bash
find data/openobserve/mmdb -maxdepth 1 -type f -ls
```

Inside the container:

```bash
docker compose exec openobserve sh -c 'ls -lah /data/mmdb'
```

Check OpenObserve logs:

```bash
docker compose logs openobserve | grep -Ei 'mmdb|maxmind|geolite'
```

If auto-download is enabled but the directory stays empty, verify DNS/HTTPS egress to the configured MMDB and SHA256 URLs.

## Air-gapped/manual mode

Disable downloads:

```dotenv
ZO_MMDB_DISABLE_DOWNLOAD=true
```

Keep the database directory at:

```dotenv
ZO_MMDB_DATA_DIR=/data/mmdb
```

Manage verified MMDB files in `./data/openobserve/mmdb` yourself and restart OpenObserve after replacing them:

```bash
docker compose restart openobserve
```

## Fields returned by `netflow_geoip`

Source endpoint:

```text
src_geo_country_code
src_geo_country_name
src_geo_city
src_geo_region
src_geo_timezone
src_geo_latitude
src_geo_longitude
src_geo_asn
src_geo_as_org
```

Destination endpoint:

```text
dst_geo_country_code
dst_geo_country_name
dst_geo_city
dst_geo_region
dst_geo_timezone
dst_geo_latitude
dst_geo_longitude
dst_geo_asn
dst_geo_as_org
```

Latitude/longitude are converted to floating-point values and ASN to an integer.

Private/internal IP addresses normally have no useful GeoLite match. Lookup failure is handled normally by the function: the related GeoIP fields are simply not added.

## Recommended NetFlow pipeline

Store and classify all flows:

```text
netflow Source
    ↓
netflow_direction
    ↓
netflow_geoip
    ↓
netflow Destination
```

If only Internet flows should be stored:

```text
netflow Source
    ↓
netflow_direction
    ↓
Condition: internet_flow = true
    ↓
netflow_geoip
    ↓
netflow Destination
```

## Test

Use an event such as:

```json
{
  "src_addr": "10.0.0.10",
  "dst_addr": "1.1.1.1"
}
```

Expected behavior:

- the private source normally receives no GeoIP fields,
- the public destination receives country/location/ASN fields when MMDB is loaded.

Current OpenObserve documentation for MaxMind configuration and enrichment:

- `https://openobserve.ai/docs/user-guide/data-processing/enrichment-tables/enrichment-example/`
- `https://openobserve.ai/docs/administration/configuration/environment-variables/`
