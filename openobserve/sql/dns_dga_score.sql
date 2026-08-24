-- OpenObserve dashboard query: DNS DGA score by client
--
-- The score is a heuristic ranking signal, not a malware verdict.
-- It intentionally exposes both the raw metrics and their normalized 0-100
-- component scores so that the final result is explainable.

WITH domain_stats AS (
    SELECT
        concat(dns_client_host, '/', dns_client_ip) AS col1,
        dns_registered_domain,
        dns_tld,
        COUNT(*) AS domain_queries
    FROM "dnslog"
    WHERE dns_client_ip IS NOT NULL
      AND dns_registered_domain IS NOT NULL
    GROUP BY
        dns_client_ip,
        dns_client_host,
        dns_registered_domain,
        dns_tld
),

metrics AS (
    SELECT
        col1,

        SUM(domain_queries) AS queries,
        COUNT(*) AS unique_domains,
        COUNT(DISTINCT dns_tld) AS unique_tlds,

        ROUND(
            1.0 * SUM(domain_queries) / COUNT(*),
            2
        ) AS queries_per_domain,

        ROUND(
            AVG(LENGTH(dns_registered_domain)),
            2
        ) AS avg_domain_length,

        ROUND(
            100.0 *
            SUM(
                LENGTH(
                    REGEXP_REPLACE(
                        dns_registered_domain,
                        '[^0-9]',
                        '',
                        'g'
                    )
                )
            )
            /
            NULLIF(
                SUM(LENGTH(dns_registered_domain)),
                0
            ),
            2
        ) AS digit_pct,

        SUM(
            CASE
                WHEN domain_queries = 1 THEN 1
                ELSE 0
            END
        ) AS singleton_domains,

        ROUND(
            100.0 *
            SUM(
                CASE
                    WHEN domain_queries = 1 THEN 1
                    ELSE 0
                END
            )
            /
            COUNT(*),
            2
        ) AS singleton_pct

    FROM domain_stats
    GROUP BY col1
    HAVING
        SUM(domain_queries) >= 100
        AND COUNT(*) >= 30
),

scores AS (
    SELECT
        *,

        -- singleton_pct: <=30% -> 0, >=90% -> 100
        LEAST(
            100.0,
            GREATEST(
                0.0,
                (singleton_pct - 30.0) / 60.0 * 100.0
            )
        ) AS singleton_score,

        -- queries_per_domain: >=10 -> 0, <=1.5 -> 100
        LEAST(
            100.0,
            GREATEST(
                0.0,
                (10.0 - queries_per_domain) / 8.5 * 100.0
            )
        ) AS qpd_score,

        -- digit_pct: <=2% -> 0, >=20% -> 100
        LEAST(
            100.0,
            GREATEST(
                0.0,
                (digit_pct - 2.0) / 18.0 * 100.0
            )
        ) AS digit_score,

        -- avg_domain_length: <=15 -> 0, >=30 -> 100
        LEAST(
            100.0,
            GREATEST(
                0.0,
                (avg_domain_length - 15.0) / 15.0 * 100.0
            )
        ) AS length_score,

        -- unique_tlds: <=5 -> 0, >=25 -> 100
        LEAST(
            100.0,
            GREATEST(
                0.0,
                (unique_tlds - 5.0) / 20.0 * 100.0
            )
        ) AS tld_score

    FROM metrics
)

SELECT
    col1,

    ROUND(
          singleton_score * 0.35
        + qpd_score       * 0.25
        + digit_score     * 0.15
        + length_score    * 0.15
        + tld_score       * 0.10,
        1
    ) AS dga_score,

    -- Raw component metrics
    queries,
    unique_domains,
    unique_tlds,
    queries_per_domain,
    avg_domain_length,
    digit_pct,
    singleton_domains,
    singleton_pct,

    -- Normalized component scores
    ROUND(singleton_score, 1) AS singleton_score,
    ROUND(qpd_score, 1) AS qpd_score,
    ROUND(digit_score, 1) AS digit_score,
    ROUND(length_score, 1) AS length_score,
    ROUND(tld_score, 1) AS tld_score

FROM scores
ORDER BY dga_score DESC
LIMIT 100;

-- Suggested dashboard coloring:
-- dga_score:          <40 green, 40-59.9 yellow, 60-74.9 orange, >=75 red
-- unique_tlds:        <=5 green, 6-10 yellow, 11-20 orange, >20 red
-- queries_per_domain: >=10 green, 5-9.99 yellow, 2-4.99 orange, <2 red
-- avg_domain_length:  <15 green, 15-19.99 yellow, 20-29.99 orange, >=30 red
-- digit_pct:          <2 green, 2-7.99 yellow, 8-14.99 orange, >=15 red
-- singleton_pct:      <30 green, 30-49.99 yellow, 50-79.99 orange, >=80 red
