# Ask: embedding and index errors

The reported “invalid response” occurred with `llama3.1:latest` selected as both chat and embedding model. Ollama accepted chat but rejected embeddings. With zero indexed chunks, Ask had no evidence to retrieve.

The fix separates model lists by Ollama's reported capabilities, replaces an incompatible saved selection during Refresh Models, preserves useful server errors, and prevents asking against an empty index. It also fixes reopening an existing index directory and prevents overlapping index starts. Answers without valid citation IDs receive one repair attempt; if that still fails, Sematrica shows the actual retrieved passages with programmatically assigned citations.

On the development Mac, `nomic-embed-text:latest` is now installed locally. Keep `llama3.1:latest` as the chat model. After opening the rebuilt app, Refresh Models, open a relevant article and choose Index Current Article. For questions spanning topics, search titles and index the relevant search results. Indexing is incremental and scoped to the current package; Sematrica does not automatically embed the entire Wikipedia package.

Verification on October 4, 2026:

- Debug build passed.
- Standard suite: 40 passed, eight opt-in integration tests skipped, zero failures.
- All 10 intelligence tests passed with external network access denied to the test process and only localhost allowed. This included actual Ollama embeddings, persistent index reopening, a cited Holland/Netherlands answer using a controlled source fixture, and a cited answer from a real downloaded Ray Charles album article.
- Real WebKit offline browser/crawler regression passed on three articles with all networking denied to the harness.
- Test model calls used existing local `llama3.1:latest`; indexing used dedicated `nomic-embed-text:latest`. No remote inference was configured. The separately running Ollama daemon was not itself sandboxed by the test; physical Wi-Fi-off acceptance remains a separate check.

The full Phase 4 semantic crawler and cross-article acceptance sequence still needs its own end-to-end verification. These results establish the Ask fix and Phase 2/3 regressions, not completion of that remaining acceptance work.
