# Conversational crawler

Start with an offline article and type into **Talk to crawler**. Word requests start Free Crawl automatically when needed. Clear grammar/spelling requests work without Ollama:

- Find all words that start with s.
- Find all verbs and highlight them.
- Highlight all verbs.
- Find all verbs starting with s and highlight them, and avoid the References section.
- Semantic hunt for volcanic activity.

“Find semantic hunt” asks what to hunt for. Stop/Pause remain immediate. The selected Chat model interprets unfamiliar wording into a validated plan, which executes automatically. No Apply step is required. The planner supports combined part-of-speech, prefix, suffix, substring, excluded-word and semantic conditions; multiple specified conditions are intersections. Natural-language refinements are interpreted with the active rule and bounded recent conversation. Semantic OR conditions use the model's semantic criterion rather than pretending to be an exact spelling test.

## Execution and communication

The crawler displays its plan/status and examines only locally observed words. Matches are highlighted using exact document ranges. Periodically it quotes up to five actual matching words in chat and steers toward their location. Semantic hunt discoveries quote observed supporting passages. It never invents page quotations to explain a failure: clarification and limitations use chat when there is no suitable evidence.

Section names are structural metadata from the isolated document-geometry bridge. Excluded sections are omitted from word classification and semantic reasoning. The crawler steers away when its sampled area is entirely excluded. This is a restriction on examination and directed movement, not a guarantee that its legs never cross a section boundary.

After at least 20 seconds with 12 unsuccessful observation batches, or 45 seconds without new matches, it may explore another article. This means “no new matches in sampled areas,” never proof of absence from the whole page. It searches the offline title index using the planned query, meaning, or prefix; then tries eligible previously observed links. “Stay in this article” prevents both routes. Rules persist through intentional transitions. A run visits at most eight articles; visited canonical paths prevent loops. New requests and Stop invalidate pending results/navigation.

## Limits

This is a bounded planner, not unrestricted autonomous intelligence. Unsupported or ambiguous plans ask for clarification; unknown plan fields and contradictory actions are rejected. The model can still misunderstand prose, and grammar tagging can miss words. Follow-up interpretation and semantic criteria need a responsive local Chat model. French-origin results are AI suggestions, not verified etymology. The crawler cannot guarantee exhaustive article coverage, browse the Internet, rewrite page text, or manufacture supporting evidence. Failed model calls leave the existing rule in place and explain the failure.

## Verification

`CrawlerIntentTests` covers sentence variants, compound filters, section constraints, clarification, range-backed matches, and strict plan validation. The WebKit command harness exercises a structured model response, automatic starting, no-travel restrictions, timed autonomous offline search, preserved rules, and stale-navigation rejection. `ATLAS_RUN_AI_INTENTS=1 swift test --filter CrawlerIntentLiveTests` opts into a real Ollama compound-plan check; it requires llama3.1:latest and can be slow.
