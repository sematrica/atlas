# The crawler's page tools

The crawler has two perception layers: nearby geometry for locomotion, and an article-wide map for explicit page tasks. The map includes rendered text blocks, hyperlink elements, image rectangles/alt text, page dimensions, viewport/scroll position, and a layout revision. It runs in WebKit's isolated content world. Article text cannot execute tools or supply JavaScript.

## Try it

Open an offline article and use **Talk to crawler**:

- `Find the longest sentence in this page`
- `Go to the longest word in this article`
- `How many hyperlinks does this page have?`
- `Go to the longest word in this article but do so only stepping on nouns or verbs`
- `What do you think of this article?`
- `Describe your environment`

The first four use deterministic page analysis after interpreting the request. Common phrasing works without a model; other phrasing uses the selected crawler chat model. Opinions require a chat model. The model name appears above the conversation. The existing provider interface is model-independent, but the app's configured provider remains local Ollama; this change does not add cloud credentials or a cloud settings screen.

## Exact behavior

Longest sentences are measured by Swift character count, words by letter count. NaturalLanguage provides sentence/word segmentation and approximate grammar tags. A tie selects one matching item. DOM ranges preserve UTF-16 offsets and inline markup, so the entire source sentence or word is highlighted. Source navigation scrolls with the crawler when Auto Follow is enabled.

The link count counts rendered hyperlink elements, including citations, same-page anchors, and repeated destinations. A tour walks to and highlights each without opening its URL, shows a running counter, and announces completion. Hidden elements and navigation/footer containers are excluded from page analysis. Image geometry is available; the model does not visually interpret image pixels.

Constrained movement means **foot landings**, not the body, must be on words tagged noun or verb. The body follows a connected route of footholds no more than 55 points apart, with a conservative gait capped at 90 points/second. The initial stance places the feet on nearby permitted words; feet may share a foothold and swing across gaps. The leg controller never substitutes a blank-space landing in this mode. If no route exists, the crawler reports the problem without relaxing the rule. Grammar tags are estimates, especially for ambiguous or non-English text.

Opinions read the mapped text in chunks, summarize each chunk, and synthesize an interpretation. They are model judgments, not verified facts. Articles above the conversational reading limit are declined with a suggestion to use Research. The model receives text, not arbitrary DOM privileges.

## Interruption and limits

Stop or another command cancels the current page action. Faster/slower changes its speed without canceling it. Pausing cancels the current page task; repeat its command to start it again. A changed layout invalidates ranges and movement targets and asks for a retry. Existing blocked destinations are checked; whole-page actions explicitly decline active section-exclusion rules they cannot apply.

The page map is bounded at two million text characters and 30,000 links/images. Truncated maps never produce purported exact totals or longest-item results. Cloud adapters, arbitrary tool composition, obstacle-aware image navigation, persistent page-action queues, and image vision are not part of this implementation.

## Validation

`CrawlerPageTests` covers measurements/UTF-16 offsets, local commands and restrictions, connected/unreachable routes, and constrained foot landings. Set `ATLAS_RUN_BODY_LIVE=1` to test a compound plan against local Ollama. The WebKit smoke harness covers real DOM maps, inline sentence and word highlights, repeated-link tours, opinion-provider execution, and rejection of stale map revisions.
