# The reading companion

Open an article and type into the panel beside it. Sematrica answers questions about the article and carries out tasks on the page. The spider is its pair of hands: it walks to text, highlights it, follows links and explores.

The panel wears the creature's look: a night-sky background, threads and nodes of white light, and one orange core. Its emblem is the creature from the app icon, cut out of its tile (`SematricaEmblem` in the asset catalog), and its core breathes while Sematrica is working. Each message is a node on a single thread: rings for you, stars for Sematrica, a pulsing core for the reply in progress, and a red ring for errors. The toolbar's **Companion** button carries the same emblem; its edge glows orange while the panel is open. The theme lives in `Constellation`, `ThreadNode`, `ConstellationEmblem` and `ConstellationBackdrop` in `Atlas/Crawler/CrawlerControls.swift`.

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
| which articles link to Paris · what links here | Lists the articles with a link to the Paris article (or the open one), whatever the link says. With a link map, every such article at once (see *Wikipedia's link map*). |
| count jazz in the articles linked in the Discography section | Adds up the matches in every article that section links to. |
| how many times is "soul" used in Ray Charles, Aretha Franklin and Sam Cooke | Reads just those articles (the model understands the list). |
| check more articles | Continues a library question that stopped after its first batch. |
| how is Ray Charles connected to Paris · connect this to the Moon | Finds the shortest chain of links between the two, walks it with the spider and draws it as a constellation (see *Connect the dots*). |
| keep looking | Continues a connection search that stopped after its first batch. |
| how many articles are in the category Jazz pianists · which articles are in Category:Jazz pianists | Counts or lists a Wikipedia category's articles (needs a link map). |
| what categories is this article in · what categories does Ray Charles belong to | Lists an article's categories (needs a link map). |

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

## Connect the dots

Ask how two articles are connected ("how is Ray Charles connected to Paris?", "connect this to the Moon", "find the shortest path from Jazz to Tokyo") and Sematrica finds the shortest chain of links from one to the other, offline. The spider then walks it: in each article it goes to the link that leads on, lights it orange and follows it. The chain is also drawn as a constellation under the reply, with each article a star, the start ringed and the destination an orange core; the threads glow as the spider crosses them. **Walk it** walks the route again, and **Copy image** and **Save image…** give a picture of the map to keep or share. Without a starting article, the open article is the start.

**How the chain is found.** The search reads outward from the start a level at a time: every article the start links to, then the articles they link to, and so on. Within a level, articles that mention the destination are read first, then those that many articles at the level link to. Meanwhile the archive's full-text search (or the Research text index) proposes up to 300 articles that mention the destination, and the ones that really link to it become stepping stones: reaching any of them completes a chain. Every link in a chain was read on the article's page, so the spider can walk it. Links that go through a redirect ("French capital" for Paris) count, and the map notes them.

**Shortest, and how sure.** Once every article within a distance of the start has been read, no shorter chain can exist, and the answer says so: "That's the shortest chain: none of the 412 articles Ray Charles links to links to Paris directly." When a chain is found before its level has been read in full, the answer says a shorter one might exist. Sematrica reads up to 2,000 articles per request; **Keep looking** (or "keep looking") continues where it stopped. With neither a full-text index nor a text index, the search can only read outward, which still finds most chains of up to three links.

With a link map built for the package's wiki, the chain comes from the map instead and is checked on the pages (next section). The answer then says it's the shortest chain in the map, rather than how many articles were read.

## Wikipedia's link map

A ZIM package holds each article's page but no index of which pages link where. Wikipedia publishes that index as table dumps, and Sematrica can turn them into a **link map**. In **Packages → Available → Wikimedia archives**, load a wiki's catalog (`enwiki`, `simplewiki`, `frwiki`…) and choose **Download the Link Map Files**. Then, under **Installed → Link maps**, choose **Build Link Map**. The build reads, in turn:

1. `page`: every article gets a number; redirects are noted.
2. `redirect`: each redirect is pointed at its article, so a link to "French capital" counts as a link to Paris.
3. `linktarget` (dumps from 2024 on, whose links point into this table instead of naming titles).
4. `pagelinks`: links between articles. Red links, links from talk or user pages, and links into other namespaces are left out.
5. Both directions of every link are sorted into per-article lists.
6. `categorylinks` (optional): which articles are directly in which categories.

The files go into `indexes/linkmap-<wiki>-<date>/` (built in a `.building` folder and renamed only when complete) and are memory-mapped when used, so opening even English Wikipedia's map takes a moment and little memory. The build checks there's enough free space first and can be cancelled. A Wikipedia package uses the newest map for its wiki, matched by the package's name (`wikipedia_en_all_maxi` → `enwiki`, `wikipedia_en_simple_all` → `simplewiki`). Other collections, like Wiktionary or Gutenberg, have no link map.

**Connect the dots with a map.** The shortest chain is found in the whole map at once, by searching from both ends; that takes well under a second even across millions of articles. Then each link of the chain is checked on the package's own pages, by reading the few articles on the chain, so the spider can still walk it. The dump and the package are made on different dates, and a ZIM can leave out the navigation boxes some links live in. So a link the pages don't have is avoided, and the map asked again; an article the package lacks is avoided the same way. The answer says how many links were avoided: "That's the shortest chain in Wikipedia's link map (2026-10-01), going around 1 link the map has that these pages don't." If the map doesn't know one of the articles (it's newer than the dump), or after eight tries the map still can't give a chain the pages share, the reading search runs as usual. If the map has no chain at all of 10 links or fewer, the answer says so straight away.

**What links here.** "Which articles link to Paris?", "what links here" and "how many articles link to this article" are answered from the map, at once, for every article in the wiki, not only those that mention the title. Each article counts once, and links through redirects are included. The list under the reply shows the articles this package has, most linked-to first. Each one opens the article and highlights its links to the page. Questions the map can't answer exactly still read articles as before: links only in one section, or "how many times" (the map doesn't count repeated links within a page the way the page does).

**Categories.** "How many articles are in the category Jazz pianists?", "which articles are in Category:Jazz pianists" and "what categories is this article in?" come from `categorylinks`. A category's count is of the articles directly in it, not in its subcategories. Maintenance categories editors use ("Articles with short description", "CS1 maint: …", "… stubs") are counted but not listed. A map built without `categorylinks` answers links but not categories.

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
- A link map is as old as its dump. Articles newer than the dump fall back to reading, and "what links here" reflects the wiki on the dump's date, not the package's.
- Building English Wikipedia's link map needs a few GB of memory and, while it runs, free space of about three times the `pagelinks` file.
