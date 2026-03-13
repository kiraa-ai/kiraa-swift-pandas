#!/bin/bash
# 11 — Large CSV: generate 100K rows, groupby + sum, output to new CSV
# Demonstrates swift run swiftpandas performance on realistic data volumes
# Usage: ./11_large_groupby_sum.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="$SCRIPT_DIR/../data"
INPUT="$DATA_DIR/transactions_100k.csv"
OUTPUT="$DATA_DIR/summary_by_region_product.csv"

mkdir -p "$DATA_DIR"

# ── Step 1: Generate a 100,000-row CSV ──
echo "Generating 100,000-row transaction dataset…"

python3 -c "
import random, csv, sys
random.seed(42)
regions   = ['North', 'South', 'East', 'West', 'Central']
products  = ['Widget', 'Gadget', 'Sprocket', 'Flange', 'Bearing', 'Bracket', 'Coupling', 'Valve']
statuses  = ['completed', 'completed', 'completed', 'pending', 'refunded']
writer = csv.writer(sys.stdout)
writer.writerow(['region', 'product', 'status', 'revenue', 'cost', 'units'])
for _ in range(100_000):
    region  = random.choice(regions)
    product = random.choice(products)
    status  = random.choice(statuses)
    units   = random.randint(1, 500)
    price   = random.uniform(5.0, 200.0)
    margin  = random.uniform(0.15, 0.55)
    revenue = round(units * price, 2)
    cost    = round(revenue * (1 - margin), 2)
    writer.writerow([region, product, status, revenue, cost, units])
" > "$INPUT"

ROWS=$(wc -l < "$INPUT" | tr -d ' ')
SIZE=$(du -h "$INPUT" | cut -f1)
echo "  Created: $INPUT ($ROWS rows, $SIZE)"
echo ""

# ── Step 2: Run the pipeline ──
echo "Running: filter(completed) | groupby(region, product) | agg(sum:revenue, sum:cost, sum:units) | sort(revenue, desc)"
echo ""

swift run swiftpandas -i "$INPUT" -o "$OUTPUT" --verbose -c "
  filter(status == \"completed\") |
  groupby(region, product)       |
  agg(sum:revenue, sum:cost, sum:units) |
  derive(profit = revenue - cost) |
  sort(revenue, desc)            |
  round(revenue, 2)              |
  round(cost, 2)                 |
  round(profit, 2)
"

echo ""
echo "=== Output: $OUTPUT ==="
head -20 "$OUTPUT"
echo "…"
echo ""

OUT_ROWS=$(wc -l < "$OUTPUT" | tr -d ' ')
OUT_SIZE=$(du -h "$OUTPUT" | cut -f1)
echo "Result: $OUT_ROWS rows, $OUT_SIZE → $OUTPUT"
