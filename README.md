# SF Bay Area's Officially Artificial News

A daily, fully AI-produced newscast for the San Francisco Bay Area, built as an end-to-end multi-model project. Three fictional toy-style anchors, each powered by a different AI model, present tech and AI news, world news, Bay Area weather, and Warriors basketball. Facts come from live data pulls, not from model memory.

> **Status: early prototype.** Only the sports data adapter is built so far. Everything else below is the planned design.

## The cast

| Anchor | Model | Segments | Personality |
|---|---|---|---|
| Big Russ | Claude | Tech and AI news, "Calling Out the Hype" | Gruff, low voice. Conservative leaning. Skeptical of hype. |
| Justice Jenny | ChatGPT | Top 3 world stories, weather | Steady and neutral. Never rattled. |
| Pat | Gemini | Warriors | Animated and passionate. Liberal leaning. Fed up with dirty play. |

The anchors are original characters. Their on-air relationships carry over from episode to episode, with randomness mixed in, so some days they get along and some days they don't.

## How an episode is made

1. **Data pulls.** News, weather, sports, and AI benchmark data are fetched and stored with source and timestamp. Every item gets a fact ID.
2. **Editor step.** A separate model call ranks the day's world stories against written criteria (scale of impact, people affected, global significance) and logs a one line reason for each pick, so bias can be audited over time.
3. **Producer.** Sets the segment order, loads the anchors' relationship mood, and draws each exchange from a weighted menu (agree, tease, bicker, blow up, make up, awkward silence) using a logged random seed.
4. **Scripts.** One model call per anchor, in a strict JSON line format. Every number in a line must point to a fact ID.
5. **Fact check.** Rejects any line whose numbers or claims do not match its fact ID, before anything is rendered.
6. **Voice and visuals (planned).** Text to speech with a distinct voice per anchor, and brick-style 3D characters in a realistic newsroom, rendered in the browser.

## Editorial rules

- Anchors never supply facts from memory. Scores and stats come from data.
- Anchors summarize in their own words and credit sources on screen.
- "Calling Out the Hype" cites a source for every AI benchmark claim and separates independent results from company reported ones.
- Pat's complaints about dirty play must tie to a documented event (a recorded flagrant foul, ejection, fine, or suspension). No claims about a real player's character or intent.
- No positions on named real politicians or candidates.

## What exists today

`espn_adapter.py` fetches the latest completed Warriors game and outputs fact-ID'd records: final score, team stats, player leaders, and documented events such as technical fouls and ejections from the play-by-play. It refuses games that are not final and stops if the scoreboard score disagrees with the box score.

```
py espn_adapter.py --latest --out facts_latest.json
py -m unittest test_espn_adapter -v
```

Python 3, standard library only, no API key. The tests use synthetic fixtures and check the adapter's logic offline.

**Data source caveat:** the adapter uses ESPN's unofficial, undocumented endpoints. They can change or disappear without notice, and their terms may not allow commercial use. That is acceptable for prototyping, and the source is isolated in one file so it can be replaced with a licensed one.

## Roadmap

- [x] Concept, cast, rundown, editorial rules
- [x] Warriors stats adapter
- [ ] Remaining data sources (world news, weather, AI benchmarks, California data center data)
- [ ] Editor step, producer and relationship mood system, fact check
- [ ] Text only prototype of a full episode script
- [ ] Voices, characters, newsroom set, and rendering
- [ ] Publishing workflow

## Disclaimer

This is an independent fan and portfolio project. It is not affiliated with or endorsed by the NBA, the Golden State Warriors, ESPN, LEGO, or any AI provider named above. All anchors are fictional.
