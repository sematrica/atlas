# The reading companion

Open an article and type into the panel beside it. Sematrica answers questions about the article and carries out tasks on the page. The spider is its pair of hands: it walks to text, highlights it, follows links and explores.

## What you can ask

Anything that combines a **target**, **conditions** and an **action**:

| You say | What happens |
| --- | --- |
| how many capital letters are in this article | Counts every uppercase letter in the rendered text. |
| how many dots / periods / commas / question marks | Counts that exact character. |
| how many links are on this page | Counts rendered hyperlinks, including repeated ones. |
| find me all the words that start with a and end with r | Highlights every match; the spider walks to them. |
| find all adjectives that end with w and highlight them in green | Same, in green. |
| highlight the verbs half green half yellow | Each verb is split into a green half and a yellow half. |
| highlight nouns in blue and verbs in alternating red and orange | Two layers, one request. |
| highlight the 5 longest words in rainbow | Ranked by letters, painted as a gradient. |
| what is the most common word except "the" and "of" | Lists it with its count. |
| go to the second longest word | The spider walks there and spotlights it. |
| walk to the longest sentence, only stepping on nouns | Every foot lands on a noun; the route fails rather than break the rule. |
| take me to the Early life section · go to the bottom | Walks to that heading or place. |
| follow the Atlantic Records link · open the article on Paris · go back | Navigates; later steps in the same request run on the new page. |
| hunt for the phrase "Atlantic Records" | The spider searches on foot, seeing only what is near it, and says when it finds it. |
| look for evidence about volcanoes in other articles | Explores by meaning across offline articles (needs a chat model). |
| wander · pause · resume · faster · slower · stop | Controls the spider. |
| stay in this article · avoid the References section · clear rules | Travel rules for exploration and following links. |
| highlight words related to music | The model judges candidate words; matches are highlighted. |
| when was he born? · what do you think of this article? | Answers from the article text; long questions read the whole article first. |
| clear the green highlights · clear highlights | Removes some or all highlight layers. |
| how many articles mention Atlantic Records | Reads every candidate article and counts exactly in each (see *Across the library*). |
| which articles link to Paris | Lists the articles with a link to the Paris article, whatever the link says. |
| count jazz in the articles linked in the Discography section | Adds up the matches in every article that section links to. |
| how many times is "soul" used in Ray Charles, Aretha Franklin and Sam Cooke | Reads just those articles (the model understands the list). |
| check more articles | Continues a library question that stopped after its first batch. |

**Targets:** words (or nouns, verbs, adjectives, adverbs…), letters, characters, numbers, sentences, paragraphs, headings, links, images, names (people, places, organizations), and exact phrases.
**Conditions:** starts with, ends with, contains or equals a spelling (with "or" alternatives), the negatives of those, part of speech, uppercase/lowercase/capitalized, length in letters or words, a section or sections to skip, unique spellings, and order (first, last, longest, shortest, most and least common, with a rank or a limit).

## How it works

1. **Instant local understanding.** `CompanionLocalParser` handles common phrasing such as counts, find and highlight with conditions and colors, go to, and controls. It accepts a request only if it understands every word; otherwise the request goes to the model. These requests need no model and answer immediately ("understood instantly" appears under the reply).
2. **One model call.** Everything else becomes a single Ollama call whose output is constrained by a JSON schema (`CompanionPlan.schema`), so even small local models can only return a well-formed plan: a short reply plus a list of steps. If a plan fails validation, Sematrica asks once more with the reason; steps that still fail are reported, never guessed.
3. **Deterministic execution.** `PageQueryEngine` runs every count, list and selection over the complete page map, so totals never come from the model's arithmetic. The model only translates the request.
4. **The spider performs.** With 15 or fewer matches the spider walks to each one and marks it. With more, it sweeps down the page and lights matches up as it passes; *Finish now* paints the rest at once. "Go to" requests walk to the target and spotlight it.

Highlights are colored **layers** that stay until cleared. Colors come from the user's own words: any CSS color name or hex value, plus everyday names (mint, peach, rose…), light and dark shades, *half … half* (split each match), *alternating* (match by match), *gradient from … to …*, *rainbow*, *half of them … the rest …* (groups), *underline*, and *text* (color the letters). The legend under the conversation lists each layer with a button to remove it.

Layers are live DOM ranges, so they survive window resizes and images loading. If the article's text itself changes, Sematrica asks you to repeat the request instead of painting stale positions.

Saved results (`r1`, `r2`…) let follow-ups refer back: "show them again", "highlight those in red", "yes" after "Want me to highlight them?".

## Across the library

A library question counts or finds in many articles at once: how many articles mention something, how many times altogether, or which articles. Search only proposes the candidates; every candidate is then read in full and counted exactly by the same engine as the open page, so a number never comes from a search engine's estimate.

**Which articles are read**

- *The whole library* (the default). Candidates come from, in order of preference:
  1. the archive's built-in full-text index, which most Kiwix ZIM files include and which covers every article;
  2. the text index built under **Research → Build / Resume Text Index**, when the archive has no built-in index. The answer says if that index isn't finished yet. Text in very short fragments (a table cell under 20 characters) isn't in that index, so an article whose only mention is in one can be missed;
  3. otherwise every article in turn, which is slow for a large package.
  Questions with nothing to search for, such as "how many capital letters in all articles", always read every article.
- *Articles linked from the open article*, optionally only from one section ("the articles linked in the Discography section").
- *Named articles* ("in Ray Charles, Aretha Franklin and Sam Cooke").
- *The best search results* for a topic.

**Reading and counting.** Each article is turned into the same page map the companion uses on screen, but straight from the archive's HTML: headings, paragraphs, list items, table cells, links and images, skipping scripts, styles, navigation, footers and hidden elements. Text that only a stylesheet hides is still counted. Links match by destination with `linksTo`, so "the French capital" pointing at Paris counts as a link to Paris. A redirect isn't followed, so a link to "Paris, France" that redirects to Paris doesn't count.

**Long questions.** Sematrica reads up to 2,000 articles per request, four at a time, and shows its progress. If more remain, the answer says so and **Check more articles** (or "check more articles") continues where it stopped.

**Results.** The reply gives the number and how complete it is. Under it, the matching articles are listed with their counts, most first. Each one opens the article and highlights what was counted there. **Copy list** copies titles and counts as tab-separated lines.

## Models

The companion works with any chat model installed in Ollama (0.5 or newer for schema output; older versions fall back to JSON mode). Under **Ask → Companion fit**:

- An instant **estimate** (Strong, Medium or Weak) from the model's size, context window and quantization.
- **Run Fit Test** sends 12 real companion requests with unusual phrasing through the model and scores how many it understood, and how fast. The result is stored per model and shown as a badge beside the model name in the companion.

Common requests run locally regardless of the model, so even a weak model handles them well.

For speed, Sematrica uses one context size for every request (changing it makes Ollama reload the model), keeps the model loaded for 30 minutes between messages, checks the model's safety once rather than on every call, and places the article opening before the conversation so Ollama can reuse its cache.

## Limits

- Grammar and name tags come from Apple's NaturalLanguage framework and are estimates, especially for ambiguous or non-English words.
- Meaning-based highlighting judges at most 600 distinct candidates per request.
- A very long article can exceed the page map's 2-million-character limit; counts then say they may be low.
- Phrase hunts are deliberately local: the spider can't see the target until it is nearby, so a hunt can take a while.
- Exploration across articles needs a chat model and stops after a bounded number of articles or evaluations.
