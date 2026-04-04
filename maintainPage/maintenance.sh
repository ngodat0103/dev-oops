#!/bin/bash

# Cloudflare Maintenance Mode Script
# This script enables or disables maintenance mode by creating/deleting a Cloudflare page rule
# that redirects all traffic to a maintenance page.

# Configuration
API_TOKEN="${CLOUDFLARE_API_TOKEN:-your_api_token_here}"
ZONE_ID="ab6606e8b3aad0b66008eb26f2dd3660"
MAINTENANCE_URL="https://maintainance.datrollout.workers.dev/"

# Function to enable maintenance mode
enable_maintenance() {
    echo "Enabling maintenance mode..."

    response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/pagerules" \
         -H "Authorization: Bearer $API_TOKEN" \
         -H "Content-Type: application/json" \
         --data '{
             "targets": [{
                 "target": "url",
                 "constraint": {
                     "operator": "matches",
                     "value": "*datrollout.dev/*"
                 }
             }],
             "actions": [{
                 "id": "forwarding_url",
                 "value": {
                     "url": "'"$MAINTENANCE_URL"'",
                     "status_code": 302
                 }
             }],
             "priority": 1,
             "status": "active"
         }')

    if echo "$response" | jq -e '.success' > /dev/null; then
        echo "Maintenance mode enabled successfully."
    else
        echo "Failed to enable maintenance mode."
        echo "Response: $response"
        exit 1
    fi
}

# Function to list current page rules
list_rules() {
    echo "Fetching page rules..."
    response=$(curl -s "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/pagerules" \
              -H "Authorization: Bearer $API_TOKEN")
    echo "API Response:"
    echo "$response" | jq '.'
    echo ""
    echo "Parsed rules:"
    echo "$response" | jq -r '.result[] | "ID: \(.id), Priority: \(.priority), Status: \(.status), Pattern: \(.targets[0].constraint.value), Action: \(.actions[0].id)"' 2>/dev/null || echo "No rules found or parsing error"
}
disable_maintenance() {
    echo "Disabling maintenance mode..."

    # Get the page rule ID for the maintenance rule
    rule_id=$(curl -s "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/pagerules" \
              -H "Authorization: Bearer $API_TOKEN" | jq -r '.result[] | select(.targets[0].constraint.value == "*datrollout.dev/*") | .id')

    if [ -z "$rule_id" ]; then
        echo "No maintenance rule found. Maintenance mode may already be disabled."
        return
    fi

    response=$(curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/pagerules/$rule_id" \
               -H "Authorization: Bearer $API_TOKEN")

    if echo "$response" | jq -e '.success' > /dev/null; then
        echo "Maintenance mode disabled successfully."
    else
        echo "Failed to disable maintenance mode."
        echo "Response: $response"
        exit 1
    fi
}

# Main script logic
case "${1:-}" in
    enable)
        enable_maintenance
        ;;
    disable)
        disable_maintenance
        ;;
    list)
        list_rules
        ;;
    *)
        echo "Usage: $0 {enable|disable|list}"
        echo ""
        echo "Environment variables:"
        echo "  CLOUDFLARE_API_TOKEN - Your Cloudflare API token"
        echo "  CLOUDFLARE_ZONE_ID   - Your Cloudflare zone ID"
        echo ""
        echo "Or update the variables in the script directly."
        exit 1
        ;;
esac