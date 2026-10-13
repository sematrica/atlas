# Updated conversation behavior

See [CrawlerIntentLoop.md](CrawlerIntentLoop.md) for the current structured planner and autonomous exploration behavior. It supersedes the older Apply/Dismiss interpreter described below.

# Talk to the crawler

Open Crawl, start a hunt or Free Crawl, and use **Talk to crawler**. Type an instruction or use the quick buttons. The panel shows the instruction, its result, current speed, travel restrictions, and the local model used for interpretation. This is typed conversation; microphone input is not included.

## Commands

| Say | What happens |
| --- | --- |
| `pause`, `wait`, `freeze` | Holds the current position and cancels pending model advice. |
| `resume`, `continue hunting` | Resumes the original hunt. Word-highlighting mode stays active if selected. |
| `stop` | Ends movement and cancels interpretation/reasoning immediately. Start a new run to move again. |
| `move faster`, `move slowly`, `normal speed` | Adjusts movement without restarting the hunt. Speed stays between 45 and 540 document points/second. Reduce Motion caps motion at 84. |
| `go left`, `go right`, `go up`, `go down` | Walks a short distance in that direction, then waits. Say resume to continue. |
| `go to Early life`, `follow Atlantic Records` | Searches nearby observed headings/links for the name, approaches it, and waits at a heading or follows an available local article link. Multiple visible matches require a more specific name. |
| `don't go to United States`, `avoid References` | Blocks matching named destinations from directed approach or link following. Matching ignores case and handles encoded/underscored article names. It does not create an invisible physical exclusion zone around unseen text. |
| `stay in this article`, `avoid links` | Prevents article transitions and backtracking. |
| `allow links`, `clear rules` | Allows local links again, or clears all travel restrictions. |
| `find only adjectives and highlight them` | Suspends the original hunt and highlights locally observed adjectives while continuing to explore. |
| `highlight nouns`, `highlight verbs`, `highlight adverbs` | Selects another local part-of-speech highlighting mode. |
| `highlight words starting with A` | Highlights locally encountered words whose spelling starts with A, ignoring case. |
| `highlight words of French origin` | Uses the selected Chat model to suggest matches from locally encountered words; these are **unverified AI suggestions**, not sourced etymology. |
| `clear highlights` | Removes word highlights and allows the original hunt to continue. |
| `status` | Reports state, speed, restrictions, highlighting mode and selected model. |

Clear direct commands do not call an LLM. Other wording is interpreted by the selected local Chat model, using bounded conversation context and nearby labels. Atlas displays the proposed action with **Apply / Dismiss** before executing it. Unsupported commands receive an explanation; the model cannot run scripts or manipulate the DOM.

## Behavior and boundaries

- Commands interrupt pending advice when they change the route or restrictions. Stop/Pause invalidate old responses; a late model reply cannot restart the creature.
- A short directed move preserves the original mission and waits on arrival. Destination discovery still uses local perception, not global article search. A name not encountered can remain pending; send resume to abandon that detour.
- Travel restrictions and speed persist across article transitions and new runs in the current session. Restrictions apply in both model-directed and user-directed link navigation and are checked again after resolving the local article.
- Grammatical classification uses Apple's on-device NaturalLanguage framework. Starting-letter rules use local word tokenization and exact prefix matching. Meaning/origin criteria use the selected Ollama Chat model. It sees only contiguous fragments inside the crawler's perception radius. No full-article text extraction is used. Classification can be imperfect with short context or unsupported languages; English was tested.
- Highlight ranges use the locally observed fragment IDs and UTF-16 offsets. The isolated bridge validates offsets against its current local range registry. It retains at most 600 marked ranges per document; clear, navigation and layout invalidation remove marks. The UI reports retained ranges, which can split a word across inline nodes.
- Conversation retains the latest 40 messages in memory. Rules retain up to 20 blocked names. Neither chat nor word annotations are written to a remote service or persisted after quitting.

## Verification

Core tests cover parsing and normalization, rejecting unsupported/model-invented actions, encoded destination exclusions, actual on-device adjective classification, and arrival/pause while preserving the original hunt.

The real WebKit harness exercises speed, pause, directional movement, travel rules, adjective highlighting, clearing, and immediate Stop, including rejection of a delayed model reply. Existing offline browsing and exact Hunt regressions remain in the harness. `ATLAS_RUN_COMMAND_AI=1` additionally checks free-form command interpretation with local `llama3.1:latest` and explicit application of the proposal.

The browser keeps the reader and crawler controls within the window. Long conversation/debug panels scroll independently, reserving space for the article. `ATLAS_BUILD_DIR=/tmp/AtlasMechanicalBuild ATLAS_DENY_NETWORK=1 Scripts/test-layout.sh` uses the real SwiftUI browser and the `/tmp/AtlasStage2LiveLibrary` test fixture to verify repeated panel toggles, expanded chat/debug, 1100×760 and 860×580 windows, and native crawler rendering. This catches layout regressions that the WebKit-only harness does not exercise.


Natural-language highlighting requests can propose `words`, `wordPrefix`, or `wordMeaning` rules. For example, “mark the verbs” or “highlight every word beginning with A” is interpreted by the Chat model; Apply activates its proposed rule. Clear direct versions execute immediately. Stop and Pause remain immediate controls.

AI word selection handles at most 64 locally observed tokens per batch, at most one request at a time, with a three-second minimum interval. The crawler briefly inspects the current area while waiting. Only integer indices into the supplied word list are accepted; invented words/ranges are rejected. Stop, Pause, navigation, and newer instructions invalidate pending results. No etymology dictionary is included: French-origin highlights are suggestions that require independent source checking. An empty batch is valid, and selected-model failures appear in the controls. Rules cover encountered words, not an instantaneous scan of the whole article.
