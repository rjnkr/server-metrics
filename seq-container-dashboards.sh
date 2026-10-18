#!/bin/sh
# Creates (or updates) one Seq dashboard per running container, named "Container - <name>", by copying the
# charts of the server metrics dashboard and pointing them at the container-metrics events of that container.
# Run it inside the server-metrics container (it has curl and jq and reaches Seq and the docker-proxy), with the
# key in a file on the server (needs the Setup permission). The key is copied in, used and removed, never printed:
#   ssh beheerder@172.16.1.1 'docker cp ~/.seq-dashboard-key server-metrics:/tmp/seq.key &&
#       docker exec -i -e SEQ_ADMIN_KEY_FILE=/tmp/seq.key -e DRY_RUN=1 server-metrics sh -s;
#       docker exec server-metrics rm -f /tmp/seq.key' < seq-container-dashboards.sh
# DRY_RUN=1 only prints what would be created; leave it out to create the dashboards.

: "${SEQ_ADMIN_URL:=http://seq}"
: "${DOCKER_URL:=http://docker-proxy:2375}"
: "${SOURCE_DASHBOARD:=}"   # title of the server metrics dashboard; default: the first one using Application = 'server-metrics'
: "${PREFIX:=Container - }"
: "${EXCLUDE:=}"            # space-separated container names to skip
: "${DRY_RUN:=}"

# The key can also come from a file, so it never appears on a command line
[ -z "$SEQ_ADMIN_KEY" ] && [ -n "$SEQ_ADMIN_KEY_FILE" ] && SEQ_ADMIN_KEY=$(tr -d ' \r\n' < "$SEQ_ADMIN_KEY_FILE")
[ -n "$SEQ_ADMIN_KEY" ] || { echo "Set SEQ_ADMIN_KEY or SEQ_ADMIN_KEY_FILE" >&2; exit 1; }

seq() { curl -sf -m 15 -H "X-Seq-ApiKey: $SEQ_ADMIN_KEY" -H "Content-Type: application/json" "$@"; }

me=$(seq "$SEQ_ADMIN_URL/api/users/current") || { echo "Seq API on $SEQ_ADMIN_URL refused the key" >&2; exit 1; }
me=$(echo "$me" | jq -r '.Id')
# A key without a user can only see shared dashboards
query="shared=true"; [ "$me" != "null" ] && query="ownerId=$me&shared=true"
dashboards=$(seq "$SEQ_ADMIN_URL/api/dashboards/?$query") || { echo "Listing dashboards failed (does the key have Setup permission?)" >&2; exit 1; }

source=$(echo "$dashboards" | jq --arg t "$SOURCE_DASHBOARD" --arg q "'" '
    if $t != "" then map(select(.Title == $t))
    else map(select(tostring | test("Application\\s*=\\s*\\\\?[\"" + $q + "]server-metrics"))) end | first // empty')
[ -n "$source" ] || { echo "Server metrics dashboard not found; set SOURCE_DASHBOARD to its title" >&2; exit 1; }
echo "Copying charts from: $(echo "$source" | jq -r .Title)"

containers=$(curl -sf -m 15 "$DOCKER_URL/containers/json") || { echo "Reading containers from $DOCKER_URL failed" >&2; exit 1; }
containers=$(echo "$containers" | jq -r '.[].Names[0] | ltrimstr("/")' | sort)

for name in $containers; do
    case " $EXCLUDE " in *" $name "*) continue ;; esac
    title="$PREFIX$name"

    # Host properties without a container equivalent are dropped with their measurement; charts left empty are removed.
    dashboard=$(echo "$source" | jq --arg name "$name" --arg title "$title" --arg q "'" '
        def map_prop:
            gsub("\\bMemTotalMB\\b"; "MemLimitMB") | gsub("\\bDiskUsedGB\\b"; "DiskUsedMB")
            # the server dashboard shows memory in GB; containers use far less, so keep MB
            | gsub("(?<p>\\b(MemUsedMB|MemLimitMB)\\))\\s*/\\s*1024"; "\(.p)");
        def unmapped: test("\\b(Load1|Load5|Load15|CpuCores|DiskFreeGB|DiskTotalGB|DiskUsedPercent)\\b");
        ("Application = " + $q + "container-metrics" + $q + " and Container = " + $q + $name + $q) as $where
        | del(.Id, .Links) | .Title = $title | .OwnerId = null | .IsProtected = false | .SignalExpression = null
        | .Charts |= (map(
              del(.Id) | .SignalExpression = null
              | .Title |= (gsub("\\bGB\\b"; "MB"))
              | .Queries |= (map(
                    del(.Id) | .Where = $where | .SignalExpression = null
                    | .Measurements |= map(select(.Value | unmapped | not) | .Value |= map_prop)
                    | select(.Measurements | length > 0)))
              | select(.Queries | length > 0))
            | if any(.[]; tostring | test("DiskUsedMB")) then . else . + [{
                  Title: "Disk (writable layer)",
                  Queries: [{ Measurements: [{ Value: "max(DiskUsedMB)", Label: "DiskUsedMB" }], Where: $where,
                              GroupBy: ["time(1h)"], DisplayStyle: { Type: "Line" } }],
                  DisplayStyle: { WidthColumns: 6, HeightRows: 1 } }] end)')

    existing=$(echo "$dashboards" | jq -r --arg t "$title" 'map(select(.Title == $t)) | first | .Id // empty')

    if [ -n "$DRY_RUN" ]; then
        echo "$title ($([ -n "$existing" ] && echo update || echo create)):"
        echo "$dashboard" | jq -r '.Charts[] | "  \(.Title): \([.Queries[].Measurements[].Value] | join(", "))"'
    elif [ -n "$existing" ]; then
        echo "$dashboard" | jq --arg id "$existing" '.Id = $id' | seq -o /dev/null -X PUT "$SEQ_ADMIN_URL/api/dashboards/$existing" --data-binary @- \
            && echo "updated: $title" || echo "updating $title failed" >&2
    else
        echo "$dashboard" | seq -o /dev/null -X POST "$SEQ_ADMIN_URL/api/dashboards/" --data-binary @- \
            && echo "created: $title" || echo "creating $title failed" >&2
    fi
done
