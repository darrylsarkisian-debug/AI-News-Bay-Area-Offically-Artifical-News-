#!/usr/bin/env python3
"""Warriors stats adapter for "SF Bay Area's Officially Artificial News".

Pulls the latest FINAL Warriors game from ESPN's unofficial site API and emits
fact-ID'd records. Anchors may only cite numbers that appear here (the fact
check step compares script lines against these IDs).

IMPORTANT
- These endpoints are undocumented and unsupported. ESPN can change them at any
  time. Their terms may not allow commercial use. Keep ALL ESPN access in this
  one file so the source can be swapped (see README section in the spec).
- Standard library only. No API key.

Usage
  python espn_adapter.py --latest                # newest completed Warriors game
  python espn_adapter.py --date 20261105         # a specific date (US/Pacific day)
  python espn_adapter.py --latest --out facts.json
"""
import argparse
import datetime as dt
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

BASE = "https://site.api.espn.com/apis/site/v2/sports/basketball/nba"
USER_AGENT = "OfficiallyArtificialNews-prototype/0.1"
SOURCE_NAME = "ESPN (unofficial site API)"
WARRIORS_ABBRS = {"GS", "GSW"}


class EspnError(Exception):
    pass


class NotFinal(EspnError):
    """Game is not completed; recorded episodes must only use final games."""


class DataMismatch(EspnError):
    """Two parts of the response disagree (e.g. scoreboard vs box score)."""


# --------------------------------------------------------------------------
# HTTP client: throttled, cached, retries only on transient errors
# --------------------------------------------------------------------------
class Client:
    def __init__(self, cache_dir=".espn_cache", ttl=300, min_interval=1.0):
        self.cache_dir = cache_dir
        self.ttl = ttl
        self.min_interval = min_interval
        self._last = 0.0
        os.makedirs(cache_dir, exist_ok=True)

    def url(self, path, params=None):
        u = BASE + path
        if params:
            u += "?" + urllib.parse.urlencode(params)
        return u

    def get(self, path, params=None, ttl=None):
        url = self.url(path, params)
        key = os.path.join(self.cache_dir, hashlib.sha1(url.encode()).hexdigest() + ".json")
        ttl = self.ttl if ttl is None else ttl
        if os.path.exists(key) and time.time() - os.path.getmtime(key) < ttl:
            with open(key, encoding="utf-8") as f:
                return json.load(f), url
        data = self._fetch_with_retry(url)
        with open(key, "w", encoding="utf-8") as f:
            json.dump(data, f)
        return data, url

    def _fetch_with_retry(self, url, attempts=3):
        for i in range(attempts):
            wait = self.min_interval - (time.time() - self._last)
            if wait > 0:
                time.sleep(wait)
            self._last = time.time()
            try:
                return self._fetch(url)
            except urllib.error.HTTPError as e:
                # 403/404/400 are not transient: do not hammer the server.
                if e.code in (429, 500, 502, 503, 504) and i < attempts - 1:
                    time.sleep(2 ** (i + 1))
                    continue
                raise EspnError(f"HTTP {e.code} for {url}") from e
            except urllib.error.URLError as e:
                if i < attempts - 1:
                    time.sleep(2 ** (i + 1))
                    continue
                raise EspnError(f"Network error for {url}: {e.reason}") from e

    def _fetch(self, url):  # overridden in tests
        req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(req, timeout=20) as r:
            return json.load(r)


# --------------------------------------------------------------------------
# Finding the game
# --------------------------------------------------------------------------
def _is_warriors(competitor):
    team = competitor.get("team", {})
    return (team.get("abbreviation") in WARRIORS_ABBRS
            or "golden state" in team.get("displayName", "").lower())


def find_warriors_game(client, date_yyyymmdd):
    """Return (event, warriors_competitor, opponent_competitor, url) or None."""
    data, url = client.get("/scoreboard", {"dates": date_yyyymmdd})
    for ev in data.get("events", []):
        comps = (ev.get("competitions") or [{}])[0].get("competitors", [])
        gs = [c for c in comps if _is_warriors(c)]
        if gs:
            opp = [c for c in comps if c is not gs[0]]
            if not opp:
                raise EspnError("Warriors game with no opponent in response")
            return ev, gs[0], opp[0], url
    return None


def is_completed(event):
    status = (event.get("status") or {}).get("type") or {}
    comp_status = ((event.get("competitions") or [{}])[0].get("status") or {}).get("type") or {}
    return bool(status.get("completed") and comp_status.get("completed", True))


def latest_final_game(client, days_back=7, today=None):
    today = today or dt.date.today()
    for i in range(days_back + 1):
        d = (today - dt.timedelta(days=i)).strftime("%Y%m%d")
        found = find_warriors_game(client, d)
        if found and is_completed(found[0]):
            return found
    return None


# --------------------------------------------------------------------------
# Parsing the box score
# --------------------------------------------------------------------------
def _int(s):
    try:
        return int(str(s).strip())
    except (ValueError, TypeError):
        return None


def parse_players(summary):
    """{team_abbr: [ {name, ejected, starter, played, stats:{label:value}} ]}"""
    out = {}
    for team_block in (summary.get("boxscore") or {}).get("players", []):
        abbr = (team_block.get("team") or {}).get("abbreviation", "?")
        rows = []
        for group in team_block.get("statistics", []):
            labels = group.get("labels") or group.get("names") or []
            for a in group.get("athletes", []):
                stats = a.get("stats") or []
                rows.append({
                    "id": (a.get("athlete") or {}).get("id"),
                    "name": (a.get("athlete") or {}).get("displayName", "Unknown"),
                    "ejected": bool(a.get("ejected")),
                    "starter": bool(a.get("starter")),
                    "played": not a.get("didNotPlay") and bool(stats),
                    "stats": dict(zip(labels, stats)),
                })
        out[abbr] = rows
    return out


def parse_team_stats(summary):
    """{team_abbr: {stat_name: (label, displayValue)}}"""
    out = {}
    for t in (summary.get("boxscore") or {}).get("teams", []):
        abbr = (t.get("team") or {}).get("abbreviation", "?")
        out[abbr] = {s.get("name", ""): (s.get("label") or s.get("abbreviation") or "",
                                         s.get("displayValue"))
                     for s in t.get("statistics", [])}
    return out


def leaders(rows, label):
    """Top value for a stat label; returns (value, [names]) including ties."""
    vals = [(_int(r["stats"].get(label)), r["name"]) for r in rows if r["played"]]
    vals = [(v, n) for v, n in vals if v is not None]
    if not vals:
        return None
    top = max(v for v, _ in vals)
    return top, [n for v, n in vals if v == top]


# --------------------------------------------------------------------------
# Building facts
# --------------------------------------------------------------------------
DIRTY_RE = re.compile(r"flagrant|ejected|ejection|technical", re.I)

# Team stat names as ESPN returns them. "turnovers" counts player turnovers; "totalTurnovers"
# adds team turnovers, so the two differ. Both are kept and keep ESPN's own labels, so the
# script must say which one it means. turnoverPoints ("Points Conceded Off Turnovers") is omitted
# because it is unclear whose points it counts. totalTechnicalFouls is omitted (duplicate of technicalFouls
# in the one game checked; re-verify if a game shows a difference).
TEAM_STATS = {
    "fieldGoalsMade-fieldGoalsAttempted", "fieldGoalPct",
    "threePointFieldGoalsMade-threePointFieldGoalsAttempted", "threePointFieldGoalPct",
    "freeThrowsMade-freeThrowsAttempted", "freeThrowPct",
    "totalRebounds", "offensiveRebounds", "assists", "steals", "blocks",
    "turnovers", "totalTurnovers", "fouls", "technicalFouls", "flagrantFouls",
    "pointsInPaint", "fastBreakPoints", "largestLead", "leadChanges",
}


def build_facts(event, gs, opp, summary, scoreboard_url, summary_url, retrieved_at,
                strict=True):
    game_id = event["id"]
    gs_abbr, opp_abbr = gs["team"]["abbreviation"], opp["team"]["abbreviation"]
    gs_score, opp_score = _int(gs.get("score")), _int(opp.get("score"))
    if gs_score is None or opp_score is None:
        raise EspnError("Missing final score in scoreboard response")

    quality = {"flags": [], "plays_available": bool(summary.get("plays")),
               "fines_and_suspensions_available": False}
    players = parse_players(summary)

    # Cross-check: scoreboard score must equal sum of player points.
    for abbr, expected in ((gs_abbr, gs_score), (opp_abbr, opp_score)):
        pts = [_int(r["stats"].get("PTS")) for r in players.get(abbr, []) if r["played"]]
        if not pts or any(p is None for p in pts):
            quality["flags"].append(f"no_player_points:{abbr}")
            continue
        if sum(pts) != expected:
            msg = f"score_mismatch:{abbr} scoreboard={expected} box_sum={sum(pts)}"
            quality["flags"].append(msg)
            if strict:
                raise DataMismatch(msg)

    facts = []

    def add(slug, kind, subject, value, display, url, **extra):
        facts.append({"id": f"{game_id}.{slug}", "kind": kind, "subject": subject,
                      "value": value, "display": display, "source": SOURCE_NAME,
                      "url": url, "retrieved_at": retrieved_at, **extra})

    winner = gs_abbr if gs_score > opp_score else opp_abbr
    add(f"score.{gs_abbr}", "final_score", gs["team"]["displayName"], gs_score,
        f"{gs['team']['displayName']} {gs_score}", scoreboard_url)
    add(f"score.{opp_abbr}", "final_score", opp["team"]["displayName"], opp_score,
        f"{opp['team']['displayName']} {opp_score}", scoreboard_url)
    add("winner", "result", winner, winner, f"Winner: {winner}", scoreboard_url)
    add("margin", "result", "margin", abs(gs_score - opp_score),
        f"Margin: {abs(gs_score - opp_score)}", scoreboard_url)
    for c in (gs, opp):
        for rec in c.get("records", []):
            if rec.get("type") == "total" or rec.get("name") == "overall":
                add(f"record.{c['team']['abbreviation']}", "record",
                    c["team"]["displayName"], rec.get("summary"),
                    f"{c['team']['displayName']} record {rec.get('summary')}", scoreboard_url)
                break

    # Team box score lines (stat names verified against a live ESPN response, Nov 2026)
    for abbr, stats in parse_team_stats(summary).items():
        for name, (label, val) in stats.items():
            if name in TEAM_STATS or "flagrant" in name.lower():
                add(f"team.{abbr}.{name}", "team_stat", abbr, val, f"{abbr} {label or name}: {val}",
                    summary_url)

    # Player leaders
    for abbr, rows in players.items():
        for label, word in (("PTS", "points"), ("REB", "rebounds"), ("AST", "assists")):
            if abbr != gs_abbr and label != "PTS":
                continue  # opponent: top scorer only
            top = leaders(rows, label)
            if top:
                val, names = top
                add(f"leader.{abbr}.{label}", "player_leader", abbr, val,
                    f"{' / '.join(names)}: {val} {word}", summary_url, athletes=names)

    # Documented events for Pat (only things ESPN actually records)
    for abbr, rows in players.items():
        for r in rows:
            if r["ejected"]:
                add(f"ejection.{abbr}.{re.sub(r'[^a-z0-9]+', '-', r['name'].lower())}",
                    "documented_event", abbr, "ejected", f"{r['name']} ejected", summary_url,
                    athletes=[r["name"]])
    id_to_name = {r["id"]: r["name"] for rows in players.values() for r in rows if r.get("id")}
    id_to_team = {r["id"]: abbr for abbr, rows in players.items() for r in rows if r.get("id")}
    team_id_to_abbr = {(t.get("team") or {}).get("id"): (t.get("team") or {}).get("abbreviation")
                       for t in (summary.get("boxscore") or {}).get("teams", [])}
    for p in summary.get("plays") or []:
        text = p.get("text", "")
        ptype = (p.get("type") or {}).get("text", "")
        if DIRTY_RE.search(f"{ptype} {text}"):
            aids = [((pt or {}).get("athlete") or {}).get("id") for pt in p.get("participants") or []]
            names = [id_to_name.get(a) for a in aids]
            # Subject = the team(s) of the players involved; a double technical names both teams.
            teams = sorted({id_to_team[a] for a in aids if a in id_to_team})
            subject = "/".join(teams) if teams else team_id_to_abbr.get((p.get("team") or {}).get("id"))
            add(f"play.{p.get('id', 'x')}", "documented_event", subject,
                ptype or "play", text, summary_url, period=(p.get("period") or {}).get("number"),
                clock=(p.get("clock") or {}).get("displayValue"), play_id=p.get("id"),
                athletes=[n for n in names if n], wallclock=p.get("wallclock"))

    return {
        "game": {"event_id": game_id, "name": event.get("name"), "date": event.get("date"),
                 "warriors": gs_abbr, "opponent": opp_abbr, "winner": winner},
        "facts": facts,
        "quality": quality,
        "notes": ["Fines and suspensions are NOT in ESPN data; Pat needs a separate source.",
                  "Facts must be cited on screen as ESPN; terms of use unverified for commercial use."],
    }


def run(client, date=None, days_back=7, strict=True, today=None):
    if date:
        found = find_warriors_game(client, date)
        if not found:
            raise EspnError(f"No Warriors game on {date}")
    else:
        found = latest_final_game(client, days_back, today)
        if not found:
            raise EspnError(f"No completed Warriors game in the last {days_back} days")
    event, gs, opp, sb_url = found
    if not is_completed(event):
        raise NotFinal(f"Game {event['id']} is not final "
                       f"({(event.get('status') or {}).get('type', {}).get('detail')})")
    summary, sum_url = client.get("/summary", {"event": event["id"]})
    retrieved = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return build_facts(event, gs, opp, summary, sb_url, sum_url, retrieved, strict=strict)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--latest", action="store_true", help="newest completed game")
    g.add_argument("--date", help="YYYYMMDD")
    ap.add_argument("--days-back", type=int, default=7)
    ap.add_argument("--lenient", action="store_true", help="flag data mismatches instead of failing")
    ap.add_argument("--out", help="write JSON here (default: stdout)")
    ap.add_argument("--cache-dir", default=".espn_cache")
    args = ap.parse_args(argv)
    try:
        result = run(Client(cache_dir=args.cache_dir), date=args.date, days_back=args.days_back,
                     strict=not args.lenient)
    except EspnError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2
    text = json.dumps(result, indent=2)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(text)
        print(f"Wrote {len(result['facts'])} facts to {args.out}; flags: {result['quality']['flags']}")
    else:
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
