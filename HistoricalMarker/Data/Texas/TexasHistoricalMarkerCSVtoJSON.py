import csv, json, gzip

INPUT = "Historical Marker_20251112_113626_6777607.csv"
OUTPUT = "tx_historical_markers.json"
ZIP = "tx_historical_markers.json.gz"

records = []
with open(INPUT, newline='', encoding='utf-8') as f:
    reader = csv.DictReader(f)
    for row in reader:
        rec = {
            "id": f"tx-thc-{row.get('AtlasNumber','').strip()}",
            "title": row.get("MarkerTitle","").strip(),
            "description": row.get("MarkerText","").strip(),
            "date_installed": row.get("YearMarkerErected",""),
            "coordinates": {
                "latitude": float(row["Latitude"]) if row.get("Latitude") else None,
                "longitude": float(row["Longitude"]) if row.get("Longitude") else None
            },
            "address": {
                "city": row.get("City",""),
                "county": row.get("County",""),
                "state": "TX"
            },
            "images": [],
            "source": [{
                "name": "Texas Historical Commission",
                "url": "https://atlas.thc.texas.gov/Data/DataDownload",
                "source_id": row.get("AtlasNumber",""),
            }],
            "type": "state marker (TX)",
            "tags": [],
            "confidence": 0.9
        }
        records.append(rec)

# Write plain JSON
with open(OUTPUT, "w", encoding="utf-8") as f:
    json.dump(records, f, ensure_ascii=False, indent=2)

# Compress to .gz (ZIP-like)
with gzip.open(ZIP, "wt", encoding="utf-8") as f:
    json.dump(records, f)

print(f"Wrote {len(records)} markers to {OUTPUT} and {ZIP}")
