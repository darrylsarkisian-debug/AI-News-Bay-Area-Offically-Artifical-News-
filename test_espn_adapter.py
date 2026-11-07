"""Offline tests. Fixtures are SYNTHETIC, shaped after the fields seen in ESPN's
scoreboard and summary responses. They test this code's logic, not ESPN's data.
Run: python -m unittest test_espn_adapter -v
"""
import copy
import datetime as dt
import tempfile
import unittest

import espn_adapter as ea

LABELS = ["MIN", "PTS", "FG", "3PT", "FT", "REB", "AST", "TO", "STL", "BLK", "OREB", "DREB", "PF", "+/-"]


def athlete(name, pts, reb, ast, ejected=False, dnp=False):
    stats = [] if dnp else ["30", str(pts), "5-10", "1-3", "2-2", str(reb), str(ast), "1", "0", "0", "1", "2", "2", "0"]
    return {"athlete": {"id": "id-" + name.replace(" ", ""), "displayName": name}, "starter": True, "didNotPlay": dnp,
            "ejected": ejected, "stats": stats}


def team_block(abbr, athletes):
    return {"team": {"abbreviation": abbr}, "statistics": [{"labels": LABELS, "athletes": athletes}]}


def scoreboard(completed=True, gs_score="110", opp_score="100", date="20261105"):
    state = {"completed": completed, "detail": "Final" if completed else "7:28 - 3rd Quarter"}
    return {"events": [{
        "id": "999", "name": "Miami Heat at Golden State Warriors", "date": "2026-11-06T03:00Z",
        "status": {"type": state},
        "competitions": [{"status": {"type": state}, "competitors": [
            {"homeAway": "home", "score": gs_score,
             "team": {"abbreviation": "GS", "displayName": "Golden State Warriors"},
             "records": [{"type": "total", "summary": "5-2"}]},
            {"homeAway": "away", "score": opp_score,
             "team": {"abbreviation": "MIA", "displayName": "Miami Heat"}, "records": []}]}]}]}


def summary(gs_pts=(40, 30, 40), opp_pts=(60, 40), plays=None, ejected=False):
    gs = [athlete("Player A", gs_pts[0], 4, 9), athlete("Player B", gs_pts[1], 12, 3, ejected=ejected),
          athlete("Player C", gs_pts[2], 2, 1), athlete("Bench DNP", 0, 0, 0, dnp=True)]
    opp = [athlete("Opp X", opp_pts[0], 5, 5), athlete("Opp Y", opp_pts[1], 6, 6)]
    s = {"boxscore": {
        "players": [team_block("GS", gs), team_block("MIA", opp)],
        "teams": [{"team": {"id": "9", "abbreviation": "GS"}, "statistics": [
            {"name": "technicalFouls", "label": "Technical Fouls", "displayValue": "1"},
            {"name": "totalTechnicalFouls", "label": "Total Technical Fouls", "displayValue": "1"},
            {"name": "totalRebounds", "label": "Rebounds", "displayValue": "44"},
            {"name": "assists", "label": "Assists", "displayValue": "36"},
            {"name": "teamTurnovers", "label": "Team Turnovers", "displayValue": "1"},
            {"name": "fieldGoalsMade-fieldGoalsAttempted", "label": "FG", "displayValue": "40-85"}]},
            {"team": {"id": "14", "abbreviation": "MIA"}, "statistics": []}]}}
    if plays is not None:
        s["plays"] = plays
    return s


class FakeClient(ea.Client):
    def __init__(self, routes):
        super().__init__(cache_dir=tempfile.mkdtemp(), ttl=0, min_interval=0)
        self.routes, self.calls = routes, []

    def _fetch(self, url):
        self.calls.append(url)
        for frag, data in self.routes.items():
            if frag in url:
                if isinstance(data, Exception):
                    raise data
                return copy.deepcopy(data)
        raise AssertionError("unexpected url " + url)


class Tests(unittest.TestCase):
    def run_adapter(self, sb, sm, **kw):
        c = FakeClient({"/scoreboard": sb, "/summary": sm})
        return ea.run(c, date="20261105", **kw), c

    def test_happy_path(self):
        res, _ = self.run_adapter(scoreboard(), summary())
        ids = {f["id"]: f for f in res["facts"]}
        self.assertEqual(ids["999.score.GS"]["value"], 110)
        self.assertEqual(ids["999.winner"]["value"], "GS")
        self.assertEqual(ids["999.margin"]["value"], 10)
        self.assertEqual(ids["999.leader.GS.PTS"]["value"], 40)
        self.assertEqual(ids["999.leader.GS.PTS"]["athletes"], ["Player A", "Player C"])  # tie kept
        self.assertEqual(ids["999.leader.GS.REB"]["athletes"], ["Player B"])
        self.assertEqual(ids["999.leader.MIA.PTS"]["athletes"], ["Opp X"])
        self.assertNotIn("999.leader.MIA.REB", ids)
        self.assertEqual(ids["999.team.GS.technicalFouls"]["value"], "1")
        self.assertEqual(ids["999.team.GS.totalRebounds"]["display"], "GS Rebounds: 44")
        self.assertEqual(ids["999.team.GS.assists"]["value"], "36")
        self.assertNotIn("999.team.GS.totalTechnicalFouls", ids)   # duplicate omitted
        self.assertNotIn("999.team.GS.teamTurnovers", ids)         # not on the allowlist
        self.assertEqual(ids["999.record.GS"]["value"], "5-2")
        self.assertEqual(res["quality"]["flags"], [])
        self.assertFalse(res["quality"]["plays_available"])

    def test_every_fact_has_source_and_url(self):
        res, _ = self.run_adapter(scoreboard(), summary())
        for f in res["facts"]:
            self.assertTrue(f["source"] and f["url"].startswith("https://") and f["retrieved_at"])
        self.assertEqual(len({f["id"] for f in res["facts"]}), len(res["facts"]))  # unique ids

    def test_dnp_not_counted_as_leader(self):
        res, _ = self.run_adapter(scoreboard(), summary())
        for f in res["facts"]:
            self.assertNotIn("Bench DNP", f.get("athletes", []))

    def test_not_final_is_rejected(self):
        with self.assertRaises(ea.NotFinal):
            self.run_adapter(scoreboard(completed=False), summary())

    def test_score_mismatch_fails_strict(self):
        with self.assertRaises(ea.DataMismatch):
            self.run_adapter(scoreboard(gs_score="112"), summary())

    def test_score_mismatch_flagged_when_lenient(self):
        res, _ = self.run_adapter(scoreboard(gs_score="112"), summary(), strict=False)
        self.assertTrue(any(f.startswith("score_mismatch:GS") for f in res["quality"]["flags"]))

    def test_ejection_and_flagrant_plays_documented(self):
        plays = [{"id": "p1", "text": "Player B flagrant foul type 1", "type": {"text": "Flagrant Foul"},
                  "period": {"number": 3}, "clock": {"displayValue": "7:28"}, "team": {"id": "9"},
                  "participants": [{"athlete": {"id": "id-PlayerB"}}, {"athlete": {"id": "id-OppX"}}],
                  "wallclock": "2026-11-06T04:00:00Z"},
                 {"id": "p2", "text": "Player C makes layup", "type": {"text": "Layup"}}]
        res, _ = self.run_adapter(scoreboard(), summary(plays=plays, ejected=True))
        kinds = [f for f in res["facts"] if f["kind"] == "documented_event"]
        slugs = {f["id"] for f in kinds}
        self.assertIn("999.play.p1", slugs)
        self.assertNotIn("999.play.p2", slugs)
        p1 = next(f for f in kinds if f["id"] == "999.play.p1")
        self.assertEqual(p1["subject"], "GS/MIA")                  # teams of the players involved
        self.assertEqual(p1["athletes"], ["Player B", "Opp X"])    # athlete ids resolved to names
        self.assertIn("999.ejection.GS.player-b", slugs)
        self.assertTrue(res["quality"]["plays_available"])

    def test_notes_say_fines_not_covered(self):
        res, _ = self.run_adapter(scoreboard(), summary())
        self.assertFalse(res["quality"]["fines_and_suspensions_available"])
        self.assertTrue(any("Fines and suspensions" in n for n in res["notes"]))

    def test_latest_skips_unfinished_and_empty_days(self):
        today = dt.date(2026, 11, 6)
        c = FakeClient({"dates=20261106": {"events": []},
                        "dates=20261105": scoreboard(completed=False),
                        "dates=20261104": scoreboard(),
                        "/summary": summary()})
        res = ea.run(c, today=today)
        self.assertEqual(res["game"]["event_id"], "999")
        self.assertTrue(any("20261104" in u for u in c.calls))

    def test_no_game_found(self):
        c = FakeClient({"/scoreboard": {"events": []}})
        with self.assertRaises(ea.EspnError):
            ea.run(c, days_back=2, today=dt.date(2026, 11, 6))

    def test_403_is_not_retried(self):
        import urllib.error
        err = urllib.error.HTTPError("u", 403, "forbidden", {}, None)
        c = FakeClient({"/scoreboard": err})
        with self.assertRaises(ea.EspnError):
            ea.run(c, date="20261105")
        self.assertEqual(len(c.calls), 1)

    def test_cache_prevents_second_fetch(self):
        c = FakeClient({"/scoreboard": scoreboard()})
        c.ttl = 600
        c.get("/scoreboard", {"dates": "20261105"})
        c.get("/scoreboard", {"dates": "20261105"})
        self.assertEqual(len(c.calls), 1)


if __name__ == "__main__":
    unittest.main()
