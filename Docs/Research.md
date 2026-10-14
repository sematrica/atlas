# Research mode

Open a downloaded ZIM package, choose **Research** in the sidebar, select a local chat model, enter a question, and click **Research This Question**. Research runs independently of the visible spider and can read articles beyond the current page.

The engine plans subquestions, searches the open archive, reads selected passages, follows offline links, records evidence, and produces a cited report. **Open / Highlight Source** opens the cited passage in the offline reader. **Copy Report** includes source titles, archive paths, and quotations. The selected chat model handles planning, reading, and synthesis; no embedding model is needed for this mode.

## Search and coverage

- Built-in ZIM full-text search is used when available.
- Otherwise, **Build / Resume Text Index** creates an on-disk SQLite FTS5 index from extracted article paragraphs. Before it finishes, research uses title search and the partial text index. This index is separate from Ask's embedding index.
- The same text index finds candidate articles for the companion's library questions ("how many articles mention …") when the archive has no built-in full-text index. See [Companion.md](Companion.md#across-the-library).
- Ordinary research is selective. It expands searches and follows links, with bounded queues and up to 60 search queries per job.
- **Sequentially review every article** enumerates the archive and processes readable HTML articles in batches. Resume until traversal and the queue finish. Images, resources, and redirects are not separate research articles.
- Each article contributes up to eight selected passages and five validated notes. Sequential mode does not read every sentence. Failed articles are counted separately; completion is not proof that every possible answer has been found.

## Saved work and controls

**Articles per batch** controls how many articles are attempted before writing a report. **Pause & Save** cancels the current model request. An interrupted article remains queued and can be retried with **Resume Saved Queue**, including after reopening Sematrica. Saved Research lists the 30 most recently updated jobs for this package; older jobs remain in the database.

To redirect, pause, edit the question, then choose **Research Revised Question**. This creates a separate notebook that retains earlier evidence while allowing articles to be reconsidered for the new question. The original notebook remains saved. Resuming an unchanged question continues its existing queue and can use a different selected chat model.

Jobs, visits, notes, and index checkpoints are stored under the library's `indexes/research-<package fingerprint>/research.sqlite`. Switching libraries or opening another package cancels active work. Keep Sematrica running for a batch to continue; this is not a background service that wakes while the app is closed.

## Evidence and model errors

Quotations must be exact substrings of retrieved passages, and report citations must refer to saved notes. This checks source provenance, not whether every model interpretation is true. Reports use up to 24 relevance-selected notes, with at most three from any article. The full collected notebook remains on disk; the screen shows its latest 100 notes.

Malformed model JSON gets one repair attempt. If the model still fails, progress remains saved and the UI reports the error. Try another chat model or resume. Research accesses the selected offline archive and local model; it does not browse the Internet or execute model-generated code.

## Verification

`ResearchTests` exercises indexing and reopen/resume, evidence validation, cancellation checkpoints, revised-question notebook isolation, and an opt-in real ZIM/Ollama run. Run the latter with `ATLAS_RUN_RESEARCH_LIVE=1` and the existing `/tmp/AtlasStage2LiveLibrary` fixture. `Scripts/test-layout.sh` checks Research and crawler layouts at regular and minimum window sizes.
