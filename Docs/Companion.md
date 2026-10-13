# Atlas companion

Browse now opens a page-aware conversation beside the article. At narrow window widths, the panel moves above the reader. The charcoal, warm amber, serif typography, processor glow, and amber foot bearings form a shared visual design. Manual hunt/debug controls live under the panel's sliders button.

## Conversation first

Select a local chat model in Ask. Talk normally in the companion panel. The model distinguishes ordinary conversation from requests for exact page measurements or a visual demonstration. Conversation uses plain-text model replies; executable page operations use a fixed tool schema. There is no phrase whitelist in the companion's send path. Manual controls retain their direct deterministic behavior.

A question such as “How many adjectives are in this article?” computes and saves exact source ranges without moving the spider. The companion receives the actual saved words for follow-up requests such as writing a sentence with them. Page selection combines a text unit (word or sentence) with an order (first, last, longest, shortest, or a length rank). A new question such as “What is the second longest word here?” measures the full page rather than inheriting the adjective filter or an unrequested section. Length ranks default to distinct spellings; equal-length words use alphabetical order. A later “highlight them”, “show them”, “prove it”, or contextual challenge can demonstrate a saved result. The finding card is also a direct demonstration button that works without another model call.

Article discussions save cited source passages as a new focused result. A subsequent request for evidence points to those passages, rather than an older grammatical selection. If the model fails to give usable source locations, the old focus is cleared so a proof request cannot tour unrelated words. Creative use of a saved finding retains its focus. General conversation is supported without starting movement. An unclear referent should produce a specific clarification.

## Context and precision

The page map contains the current rendered article's text, sections, links, image geometry, dimensions, and viewport. Exact counts inspect the complete bounded map. Grammar uses local NaturalLanguage tags, which are estimates, especially for ambiguous and non-English text. Results count occurrences, not unique spellings.

Focused discussion sends introductory and question-relevant source blocks to the model, plus recent turns and saved findings. Broad requests for an article-level summary or opinion read every block of the available page map in bounded chunks and retain concise notes for later follow-ups. The panel discloses whether it has full-page notes or selected excerpts. A truncated page map remains partial; the model does not see image pixels or automatically know facts beyond supplied text. Source IDs must refer to supplied blocks. This verifies source location, not the truth of a model's interpretation.

The companion retains the latest eight findings and uses recent conversation entries as model history. Conversation and findings are session memory, not a persistent chat archive. Navigation cancels pending actions, changes the current-page context, and clears an obsolete focused finding. Old results cannot be demonstrated on another page. Unchanged text can be demonstrated after resizing by resolving fresh geometry; changed content requires a new finding.

## Demonstrations

The spider visits saved ranges and highlights them cumulatively with a running counter. Asking what a word is only returns the measurement; asking Atlas to go to it starts a journey and highlights the real text on arrival. Noun/verb-only stepping constrains each foot landing to tagged page words; if no connected route reaches the target, Atlas reports that failure without relaxing the rule or highlighting an unreachable word. The model's page-action plan is checked against explicit target, movement, and foot constraints in the user's request before execution. Its tour pace is capped so the legs can keep up, and a stale foothold cannot draw a page-spanning limb. It never opens a hyperlink merely to point to it. Stop cancels model work or a demonstration; findings remain available. Reduce Motion remains respected. Long articles can still take time to tour.

Local-model quality and speed affect understanding. Timeouts preserve findings and explain that the model failed to answer rather than blaming the user's phrasing. The current configured provider is Ollama. Cloud-provider configuration and unrestricted tool/code execution are not included.

## Verification

`CompanionTests` covers grammar filtering, ordered and ranked selections, request-plan consistency, article coverage, and opt-in real-model checks (`ATLAS_RUN_COMPANION_LIVE=1`). The WebKit harness can run a self-contained article (`ATLAS_COMPANION_ONLY=1`) to verify counting without movement, creative use of saved words, a fresh rank, discussion evidence, requested proof, a restricted-foot journey, and an honest disconnected-route failure; `ATLAS_COMPANION_LIVE=1` and `ATLAS_EMBODIED_LIVE=1` additionally check the installed local model. The layout harness checks both wide and minimum window sizes and captures the companion's appearance.

### Chat without an article

With no page open, messages use ordinary text generation rather than the page-tool JSON planner. Greetings and general conversation require only a working chat model. Page-related requests explain that an article needs to be opened. For page-aware structured replies, discussion and clarification decisions must include a nonempty answer; transport/model errors are displayed but excluded from subsequent model conversation history.
