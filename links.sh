#!/bin/bash

# Link testing script for Fumadocs documentation
# Extracts links from MDX files, converts to rendered URLs, tests against dev server.
# Assumes the local dev server is already running at DEV_URL, see run-local-dev.sh.
# Output file is hardcoded in OUTPUT_FILE.
# Usage: ./links.sh

OUTPUT_FILE="links.md"
DEV_URL="http://localhost:3000"

echo "Starting link verification..."

# Check that dev server is running
echo "Checking if dev server is available at ${DEV_URL}..."
code=$(curl --connect-timeout 2 -s -o /dev/null -w "%{http_code}" "${DEV_URL}/" 2>/dev/null || echo "000")
if [[ ! "$code" =~ ^20|^30 ]]; then
    echo "ERROR: Dev server not available at ${DEV_URL} (HTTP $code)"
    echo "Please start the dev server first (e.g., ./run-local-dev.sh)"
    exit 1
fi
echo "Dev server is available (HTTP $code)!"

# Get list of all MDX files
echo "Discovering MDX files..."
MDX_FILES=$(mktemp)
trap "rm -f $MDX_FILES" EXIT

find content/docs -name "*.mdx" -type f | sort > "$MDX_FILES"
total_files=$(wc -l < "$MDX_FILES")
echo "Found $total_files MDX files to process"

# Collect all links with their source
LINKS_DATA=$(mktemp)

# Function to convert a relative link to a URL path
# Fumadocs routing: content/docs/path/to/page.mdx -> /en/docs/path/to/page
# Index pages: content/docs/path/index.mdx -> /en/docs/path/
resolve_link() {
    local source_file="$1"  # e.g., content/docs/additional-information/virtual-networking.mdx
    local link="$2"          # e.g., ../iaas-cloud/how-to-guides/accessing-instances

    # Strip fragment and query string for path resolution
    local fragment=""
    local query=""

    if [[ "$link" == *#* ]]; then
        fragment="#${link#*#}"
        link="${link%%#*}"
    fi

    if [[ "$link" == *\?* ]]; then
        query="?${link#*\?}"
        link="${link%%\?*}"
    fi

    # Handle absolute paths starting with /
    if [[ "$link" == /* ]]; then
        if [[ "$link" == /en/docs/* ]]; then
            echo "${link}${query}${fragment}"
            return
        fi
        echo "/en/docs${link}${query}${fragment}"
        return
    fi

    # Get the directory containing the source file (relative to content/docs)
    # First strip the content/docs/ prefix
    local relative_file="${source_file#content/docs/}"
    local source_dir="${relative_file%/*}"
    if [[ "$source_dir" == "$relative_file" ]]; then
        source_dir=""
    fi

    local is_index=false
    if [[ "$relative_file" == */index.mdx ]] || [[ "$relative_file" == "index.mdx" ]]; then
        is_index=true
    fi

    # Start with source directory as our base
    local IFS='/'
    read -ra base_parts <<< "$source_dir"
    local base_count=${#base_parts[@]}

    # For index pages, treat ./ links as if they start from the parent directory
    local index_up_level=0
    if [[ "$is_index" == true ]]; then
        # Index pages are rendered one level "higher" - their base for relative links is their parent
        # So from dir1/dir2/index.mdx, a link ./dir3/page resolves to /en/docs/dir1/dir3/page
        # This is equivalent to ../dir3/page from dir1/dir2/somepage.mdx
        index_up_level=1
    fi

    # Apply the index level adjustment to base_count
    base_count=$((base_count - index_up_level))
    if [ $base_count -lt 0 ]; then
        base_count=0
    fi

    # Process each component of the link path
    read -ra link_parts <<< "$link"
    local link_count=${#link_parts[@]}
    local i=0

    while [ $i -lt $link_count ]; do
        local component="${link_parts[$i]}"

        if [[ "$component" == "." ]]; then
            # Current directory - skip
            ((i++))
        elif [[ "$component" == ".." ]]; then
            # Go up one directory
            if [ $base_count -gt 0 ]; then
                ((base_count--))
            fi
            ((i++))
        else
            # Regular path component - will be appended later
            break
        fi
    done

    # Build the resolved path
    local resolved_parts=()
    for ((j=0; j<base_count; j++)); do
        resolved_parts+=("${base_parts[$j]}")
    done

    # Add remaining link components
    while [ $i -lt $link_count ]; do
        resolved_parts+=("${link_parts[$i]}")
        ((i++))
    done

    # Convert array to path string
    local url_path=""
    for part in "${resolved_parts[@]}"; do
        if [[ -n "$url_path" ]]; then
            url_path="$url_path/$part"
        else
            url_path="$part"
        fi
    done

    # Handle index.mdx -> remove the filename, keep directory with trailing slash
    if [[ "$url_path" == */index.mdx ]]; then
        url_path="${url_path%/index.mdx}/"
    elif [[ "$url_path" == *.mdx ]]; then
        url_path="${url_path%.mdx}"
    fi

    # Build final URL
    if [[ -n "$url_path" ]]; then
        echo "/en/docs/${url_path}${query}${fragment}"
    else
        echo "/en/docs/${query}${fragment}"
    fi
}

echo "Extracting links from MDX files..."

while IFS= read -r mdx_file; do
    # Read the file content
    content=$(cat "$mdx_file")

    # Extract inline links [text](url) - excluding image syntax ![...](...)
    while IFS= read -r link; do
        [[ -z "$link" ]] && continue
        # Skip external links
        [[ "$link" =~ ^https?:// ]] && continue
        # Skip mailto, tel, javascript, data, etc.
        [[ "$link" =~ ^(mailto:|tel:|javascript:|data:) ]] && continue
        # Skip anchor-only links
        [[ "$link" =~ ^# ]] && continue

        resolved=$(resolve_link "$mdx_file" "$link")
        echo "${mdx_file}|${link}|${resolved}" >> "$LINKS_DATA"
    done < <(echo "$content" | grep -oP '(?<!\!)\[.*?\]\(\K[^)]+' 2>/dev/null)

    # Extract reference-style links [text][ref] and their definitions [ref]: url
    # First, collect reference definitions
    declare -A ref_defs
    while IFS= read -r ref_line; do
        ref_name=$(echo "$ref_line" | grep -oP '^\[.*?\]:' | tr -d '[]:' | tr '[:upper:]' '[:lower:]')
        ref_url=$(echo "$ref_line" | grep -oP ':\s*\K.*$' | tr -d ' ')
        if [[ -n "$ref_name" ]] && [[ -n "$ref_url" ]]; then
            ref_defs["$ref_name"]="$ref_url"
        fi
    done < <(echo "$content" | grep -E '^\[[a-zA-Z0-9_-]+\]:\s*' 2>/dev/null)

    # Now find reference links [text][ref]
    while IFS= read -r ref_link; do
        [[ -z "$ref_link" ]] && continue
        ref_name=$(echo "$ref_link" | tr '[:upper:]' '[:lower:]')

        if [[ -n "${ref_defs[$ref_name]}" ]]; then
            url="${ref_defs[$ref_name]}"
            # Skip external links
            [[ "$url" =~ ^https?:// ]] && continue
            # Skip mailto, tel, javascript, data, etc.
            [[ "$url" =~ ^(mailto:|tel:|javascript:|data:) ]] && continue
            # Skip anchor-only links
            [[ "$url" =~ ^# ]] && continue

            resolved=$(resolve_link "$mdx_file" "$url")
            echo "${mdx_file}|${url}|${resolved}" >> "$LINKS_DATA"
        fi
    done < <(echo "$content" | grep -oP '\[[^\]]*\]\[\K[^\]]*(?=\])' 2>/dev/null)

    unset ref_defs
    declare -A ref_defs

done < "$MDX_FILES"

# Sort and deduplicate
sort -u "$LINKS_DATA" -o "$LINKS_DATA"

total_links=$(wc -l < "$LINKS_DATA")
echo "Found $total_links internal links to test"

if [ "$total_links" -eq 0 ]; then
    echo "No links found!"
    rm -f "$LINKS_DATA"
    exit 0
fi

# Process each link and collect results
RESULTS_FILE=$(mktemp)
success_count=0
redirect_count=0
error_count=0

echo "Testing links..."

line_num=0
while IFS='|' read -r source_file original_link resolved_url; do
    ((line_num++))

    # Test the URL
    http_code=$(curl -s -L --max-time 10 -o /dev/null -w "%{http_code}" "${DEV_URL}${resolved_url}" 2>/dev/null || echo "000")

    # Store result
    echo "${line_num}|${source_file}|${original_link}|${resolved_url}|${http_code}" >> "$RESULTS_FILE"

    # Count by status
    if [[ "$http_code" == "200" ]]; then
        ((success_count++))
    elif [[ "$http_code" =~ ^30 ]]; then
        ((redirect_count++))
    else
        ((error_count++))
    fi

    # Progress indicator
    if [ $((line_num % 50)) -eq 0 ]; then
        echo "  Processed $line_num/$total_links links..."
    fi
done < "$LINKS_DATA"

# Generate markdown report
echo "Generating report..."

cat > "$OUTPUT_FILE" << EOF
# Link Test Results (From MDX Files)

## Broken Links (4xx/5xx Errors)

| # | Source File | Original Link | Resolved URL | HTTP |
|---|-------------|---------------|--------------|------|
EOF

# Add only error results to the main table
while IFS='|' read -r num source original resolved code; do
    if [[ ! "$code" == "200" ]] && [[ ! "$code" =~ ^30 ]]; then
        printf "| %s | \`%s\` | \`%s\` | \`%s\` | %s |\n" "$num" "$source" "$original" "$resolved" "$code" >> "$OUTPUT_FILE"
    fi
done < "$RESULTS_FILE"

cat >> "$OUTPUT_FILE" << EOF

## All Links Summary

| Status | Count |
|--------|-------|
| 200 OK | $success_count |
| 3xx Redirect | $redirect_count |
| 4xx/5xx Errors | $error_count |

**Total: $total_links links tested across $total_files MDX files**
EOF

# Cleanup
rm -f "$RESULTS_FILE" "$LINKS_DATA"

echo ""
echo "Link verification complete!"
echo "Results written to: $OUTPUT_FILE"
echo ""
echo "Summary:"
echo "  - MDX files processed: $total_files"
echo "  - 200 OK: $success_count"
echo "  - 3xx Redirect: $redirect_count"
echo "  - 4xx/5xx Errors: $error_count"
echo "  - Total links: $total_links"
