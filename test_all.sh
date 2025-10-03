#!/bin/bash
# ==========================================
# test_all.sh - Test Solana Balance API
# ==========================================

API_URL="http://18.143.78.252:8080/api/get-balance"
API_KEY="solana-api-key"
OUTPUT_DIR="./api_test_results"
WALLET_SINGLE="3NdjYB1tMdx1F3zq1ZzUkd5kX1b1x3ZqEJK1hfs6cGPa" #example
WALLET_MULTIPLE=("WalletAddr1" "WalletAddr2" "WalletAddr3") # Replace with original wallet if you want
mkdir -p "$OUTPUT_DIR"

echo "========== 1) Single Wallet =========="
curl -s -w "\nHTTP_CODE:%{http_code}\n" \
  -X POST "$API_URL" \
  -H "Content-Type: application/json" \
  -H "x-api-key: $API_KEY" \
  -d "{\"wallets\":[\"$WALLET_SINGLE\"]}" \
  --max-time 10 > "$OUTPUT_DIR/single_wallet.json"
cat "$OUTPUT_DIR/single_wallet.json"

echo -e "\n========== 2) Multiple Wallets =========="
WALLET_JSON=$(printf '"%s",' "${WALLET_MULTIPLE[@]}")
WALLET_JSON="[${WALLET_JSON%,}]"
curl -s -w "\nHTTP_CODE:%{http_code}\n" \
  -X POST "$API_URL" \
  -H "Content-Type: application/json" \
  -H "x-api-key: $API_KEY" \
  -d "{\"wallets\":$WALLET_JSON}" \
  --max-time 20 > "$OUTPUT_DIR/multiple_wallets.json"
cat "$OUTPUT_DIR/multiple_wallets.json"

echo -e "\n========== 3) 5 Concurrent Requests (Cache/Mutex Test) =========="
for i in {1..5}; do
  curl -s -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -H "x-api-key: $API_KEY" \
    -d "{\"wallets\":[\"$WALLET_SINGLE\"]}" \
    --max-time 10 > "$OUTPUT_DIR/concurrent_$i.json" &
done
wait
for i in {1..5}; do
  echo "---- response $i ----"
  cat "$OUTPUT_DIR/concurrent_$i.json"
done

echo -e "\n========== 4) Rate Limiting Test (>10 req/min) =========="
for i in $(seq 1 12); do
  curl -s -o "$OUTPUT_DIR/rate_$i.json" \
    -w "req:$i HTTP_CODE:%{http_code}\n" \
    -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -H "x-api-key: $API_KEY" \
    -d "{\"wallets\":[\"$WALLET_SINGLE\"]}" --max-time 5 &
done
wait

echo -e "\n---- Rate Limiting Summary ----"
for i in $(seq 1 12); do
  STATUS_CODE=$(grep "HTTP_CODE" "$OUTPUT_DIR/rate_$i.json" || echo "200")
  echo "Request $i: $STATUS_CODE"
done

echo -e "\nAll tests done. Results saved in $OUTPUT_DIR/"
