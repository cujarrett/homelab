---
description: Report public site traffic. Who visited, from where, on what device, which pages, and for how long. Pass today (default), yesterday, week, last-week, month, last-month or a date (YYYY-MM-DD).
---

Report visitor traffic across the public sites for one period. Read only. Done means the report below is in chat.

Days run midnight to midnight in `America/Chicago`. Weeks start on Monday.

| Argument | Period |
|---|---|
| none or `today` | Today so far |
| `yesterday` | Yesterday |
| `week` | Monday this week to now |
| `last-week` | Monday to Sunday of last week |
| `month` | The 1st of this month to now |
| `last-month` | All of last month |
| `YYYY-MM-DD` | That one day |

## What the data holds

Traefik access logs in Loki, under `log_type=~"access|sandbox"`. Alloy shapes them first, in [alloy.yaml](../../cluster/monitoring/alloy.yaml). Loki keeps them 365 days.

- Visitor data starts on 2026-10-23, when Alloy began labelling these lines. Earlier days return zero lines. Say so when the period starts before then.

- `request_Cf-Connecting-Ip`: a salted hash of the IP, not the IP. One hash is one visitor.
- `request_Cf-Ipcity`, `request_Cf-Region-Code`: the city and state Cloudflare guessed from the IP.
- Non-US visitors, known bots and requests with no User-Agent never reach Loki.
- Request duration is not logged. Time on site is the gap between a visit's first and last page view, so a one-page visit reads 0 minutes.
- `kentjarrett.com` and `mattjarrett.com` arrive with no city. Their Cloudflare zones lack the "Add visitor location headers" managed transform. Report their place as unknown.

## 1. Fetch the period

Work in the scratchpad. The fetch runs one day at a time, so no single query hits Loki's 5000-line cap. The query keeps page views only. It drops machine hosts, assets, API calls and health checks.

```bash
A="$ARGUMENTS"
export TZ=America/Chicago
TODAY=$(date +%F); TOMORROW=$(date -v+1d +%F)
MONDAY=$(date -v-$(( $(date +%u) - 1 ))d +%F)
case "${A:-today}" in
  today)      S=$TODAY;  E=$TOMORROW ;;
  yesterday)  S=$(date -v-1d +%F); E=$TODAY ;;
  week)       S=$MONDAY; E=$TOMORROW ;;
  last-week)  S=$(date -j -v-7d -f %F "$MONDAY" +%F); E=$MONDAY ;;
  month)      S=$(date +%Y-%m-01); E=$TOMORROW ;;
  last-month) S=$(date -v1d -v-1m +%F); E=$(date +%Y-%m-01) ;;
  *)          S=$A; E=$(date -j -v+1d -f %F "$A" +%F) ;;
esac
echo "$S to $E (end not included)"

Q='{log_type=~"access|sandbox"} | json | RequestHost!~"argocd-webhook.*|oidc.*|demo[0-9]-api.*" | RequestMethod="GET" | RequestPath!~".*\\.(js|css|png|jpe?g|gif|svg|ico|webp|avif|woff2?|ttf|map|webmanifest|xml|txt|json|php)(\\?.*)?" | RequestPath!~"/(api|stats|wp-json|wp-admin|wp-content|wp-includes|ghost|members|content|assets|public)/.*|/feed/?|/healthz|/undefined"'
rm -f day-*.json
k -n monitoring port-forward svc/loki 3100:3100 >/dev/null 2>&1 & sleep 3
d=$S
while [ "$d" != "$E" ]; do
  n=$(date -j -v+1d -f %F "$d" +%F)
  curl -sG localhost:3100/loki/api/v1/query_range --data-urlencode "query=$Q" --data-urlencode limit=5000 \
    --data-urlencode start=$(date -j -f '%F %T' "$d 00:00:00" +%s)000000000 \
    --data-urlencode end=$(date -j -f '%F %T' "$n 00:00:00" +%s)000000000 > day-$d.json
  echo "$d $(jq '[.data.result[].values[]] | length' day-$d.json)"
  d=$n
done
kill %1
jq -s '{data: {result: [.[].data.result[]]}}' day-*.json > period.json
```

A day showing 5000 lines was cut short. Fetch that day again as two halves.

## 2. Group into visits and judge them

A visit is one visitor's page views with no gap over 30 minutes. The User-Agent filter keeps real browsers and drops crawlers that slipped past Alloy, such as `facebookexternalhit` and `CensysInspect`.

A visit gets `bot: true` when any of these hold.

- Datacenter city: Ashburn VA, Santa Clara CA, Council Bluffs IA, Boardman OR, Columbus OH, The Dalles OR, San Jose CA. These are AWS, Google and Azure regions.
- Five or more sites inside one minute. That is a link checker, not a reader.
- Linux desktop, one view, unknown place, sharing its start minute with another such visit. That is a spread-out crawler.

```bash
cat > visits.jq <<'EOF'
def t: sub("\\.[0-9]+Z$"; "Z") | fromdate;
def device: if test("iPhone") then "iPhone" elif test("iPad") then "iPad" elif test("Android") then "Android"
  elif test("Macintosh") then "Mac" elif test("Windows") then "Windows" else "Linux" end;
[.data.result[].values[][1] | fromjson
  | select(.DownstreamStatus < 400)
  | select(.["request_User-Agent"] | test("^Mozilla/5\\.0 \\((iPhone|iPad|Linux; Android|Macintosh|Windows|X11)") and (test("compatible;")|not))]
| group_by(.["request_Cf-Connecting-Ip"])
| map(sort_by(.time)
    | reduce .[] as $r ([]; if length > 0 and (($r.time|t) - (.[-1][-1].time|t)) <= 1800
        then .[-1] += [$r] else . + [[$r]] end)
    | .[])
| map({
    place: (if .[0]["request_Cf-Ipcity"] then "\(.[0]["request_Cf-Ipcity"]), \(.[0]["request_Cf-Region-Code"])" else "unknown" end),
    device: (.[0]["request_User-Agent"] | device),
    day: (.[0].time | t | localtime | strftime("%a %m-%d")),
    start: (.[0].time | t | localtime | strftime("%m-%d %H:%M")),
    minutes: (((.[-1].time|t) - (.[0].time|t)) / 60 | floor),
    views: length,
    site_views: (group_by(.RequestHost) | map({key: .[0].RequestHost, value: length}) | from_entries),
    pages: (map(.RequestHost + .RequestPath) | unique)
  })
| (map(select(.device == "Linux" and .views == 1 and .place == "unknown")) | group_by(.start) | map(select(length > 1) | .[0].start)) as $waves
| map(. + {bot: (
    (.place | test("^(Ashburn, VA|Santa Clara, CA|Council Bluffs, IA|Boardman, OR|Columbus, OH|The Dalles, OR|San Jose, CA)$"))
    or (.minutes < 1 and (.site_views | length) >= 5)
    or (.device == "Linux" and .views == 1 and .place == "unknown" and (.start as $s | $waves | index($s) != null))
  )})
| sort_by(.start)
EOF
jq -f visits.jq period.json > visits.json
jq '{visits: length, human: map(select(.bot | not)) | length}' visits.json
```

Read `visits.json` for the report. Per-site page views come from `site_views`, so a visit across six sites counts each view once.

## 3. Report

Lead with one line: the period, total visits, how many look human and how many look automated. Then use the shape that fits the period.

One day:

1. A table per site: site, human visits, page views, longest visit in minutes.
2. A visits table for human visits with two or more views or over 0 minutes: start time, place, device, minutes, pages. Strip the scheme and shorten long paths.
3. One-page visits as a count per site, not as rows.

More than one day:

1. A table per day: day, human visits, page views.
2. A table per site: site, human visits, page views, longest visit in minutes.
3. The top 10 pages by human visits.
4. The top 10 places by human visits.
5. The 10 longest human visits: start, place, device, minutes, pages.

Then one line per automated group seen, such as a crawler, datacenter hits or a link checker. Add one line only for something unusual, such as a visit over 30 minutes, a new city or a spike on one page.
