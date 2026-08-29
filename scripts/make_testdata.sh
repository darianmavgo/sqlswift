#!/usr/bin/env bash
set -e

mkdir -p testdata

echo "Generating testdata/sample.db..."
rm -f testdata/sample.db

sqlite3 testdata/sample.db <<'EOF'
-- 1. Style metadata table
CREATE TABLE _style (key TEXT PRIMARY KEY, value TEXT);
INSERT INTO _style VALUES ('title', 'Sensor Telemetry & Hardware Hub');
INSERT INTO _style VALUES ('accent', '#0f9d58');
INSERT INTO _style VALUES ('theme', 'dark');

-- 2. Navigation metadata table
CREATE TABLE _nav (table_name TEXT PRIMARY KEY, label TEXT, position INTEGER, hidden INTEGER);
INSERT INTO _nav VALUES ('telemetry', 'Live Sensor Telemetry', 1, 0);
INSERT INTO _nav VALUES ('devices', 'Hardware Units', 2, 0);
INSERT INTO _nav VALUES ('events', 'System Log Events', 3, 0);
INSERT INTO _nav VALUES ('internal_debug', 'Debug Buffer', 9, 1);

-- 3. Hardware devices table
CREATE TABLE devices (
    id INTEGER PRIMARY KEY,
    serial_num TEXT NOT NULL UNIQUE,
    model TEXT NOT NULL,
    firmware_ver TEXT NOT NULL,
    battery_pct REAL,
    status TEXT NOT NULL
);

INSERT INTO devices VALUES (1, 'SN-A1092', 'ProSense-X1', 'v2.4.1', 98.5, 'ONLINE');
INSERT INTO devices VALUES (2, 'SN-A1093', 'ProSense-X1', 'v2.4.1', 87.2, 'ONLINE');
INSERT INTO devices VALUES (3, 'SN-B2044', 'FieldLogger-9', 'v1.9.0', 42.0, 'MAINTENANCE');
INSERT INTO devices VALUES (4, 'SN-B2045', 'FieldLogger-9', 'v1.9.0', 15.4, 'LOW_BATTERY');
INSERT INTO devices VALUES (5, 'SN-C3010', 'WeatherVane-3D', 'v3.0.2', 100.0, 'ONLINE');

-- 4. Telemetry data table (10,000 rows)
CREATE TABLE telemetry (
    id INTEGER PRIMARY KEY,
    device_id INTEGER NOT NULL REFERENCES devices(id),
    timestamp TEXT NOT NULL,
    temperature REAL NOT NULL,
    humidity REAL NOT NULL,
    pressure REAL NOT NULL,
    raw_payload BLOB
);

WITH RECURSIVE cnt(x) AS (
    SELECT 1
    UNION ALL
    SELECT x + 1 FROM cnt WHERE x < 10000
)
INSERT INTO telemetry
SELECT 
    x,
    ((x % 5) + 1),
    strftime('%Y-%m-%d %H:%M:%S', '2026-08-20 00:00:00', '+' || (x * 10) || ' seconds'),
    round(18.0 + (abs(random() % 1500) / 100.0), 2),
    round(40.0 + (abs(random() % 4500) / 100.0), 2),
    round(1013.25 + (abs(random() % 4000) / 100.0), 2),
    zeroblob(32 + (x % 128))
FROM cnt;

-- 5. System events table
CREATE TABLE events (
    id INTEGER PRIMARY KEY,
    event_type TEXT NOT NULL,
    severity TEXT NOT NULL,
    message TEXT NOT NULL,
    occurred_at TEXT NOT NULL
);

INSERT INTO events VALUES (1, 'SYSTEM_START', 'INFO', 'Telemetry gateway initialized successfully', '2026-08-20 00:00:00');
INSERT INTO events VALUES (2, 'CALIBRATION', 'INFO', 'Field sensor auto-calibration completed', '2026-08-20 01:15:20');
INSERT INTO events VALUES (3, 'BATTERY_ALERT', 'WARN', 'Device SN-B2045 dropped below 20% capacity threshold', '2026-08-20 04:30:11');
INSERT INTO events VALUES (4, 'FIRMWARE_CHECK', 'INFO', 'Firmware v2.4.1 hash verified', '2026-08-20 08:00:00');
INSERT INTO events VALUES (5, 'HEARTBEAT_ACK', 'INFO', 'Mesh cluster sync acknowledged across 5 nodes', '2026-08-20 12:00:00');

-- 6. Hidden internal table
CREATE TABLE internal_debug (
    tick INTEGER,
    dump_hex TEXT
);
INSERT INTO internal_debug VALUES (1, '0xDEADBEEF'), (2, '0xCAFEBABE');

-- Run ANALYZE so sqlite_stat1 is populated for O(1) row-count estimates
ANALYZE;

EOF

echo "Generating testdata/benchmark.db (100,000 rows)..."
rm -f testdata/benchmark.db

sqlite3 testdata/benchmark.db <<'EOF'
CREATE TABLE readings (
    id INTEGER PRIMARY KEY,
    sensor_id TEXT NOT NULL,
    metric_a REAL NOT NULL,
    metric_b REAL NOT NULL,
    metric_c REAL NOT NULL,
    status TEXT NOT NULL,
    payload BLOB
);

WITH RECURSIVE cnt(x) AS (
    SELECT 1
    UNION ALL
    SELECT x + 1 FROM cnt WHERE x < 100000
)
INSERT INTO readings
SELECT 
    x,
    'SENSOR-' || ((x % 100) + 1),
    round(10.0 + (abs(random() % 8000) / 100.0), 3),
    round(50.0 + (abs(random() % 5000) / 100.0), 3),
    round(1000.0 + (abs(random() % 20000) / 100.0), 3),
    CASE (x % 4) WHEN 0 THEN 'NORMAL' WHEN 1 THEN 'ELEVATED' WHEN 2 THEN 'CRITICAL' ELSE 'OFFLINE' END,
    zeroblob(64 + (x % 64))
FROM cnt;

ANALYZE;
EOF

echo "Done! Test databases created in testdata/"
ls -lh testdata/
