# Real Pages input fixtures

Unmodified Pages 4 and Pages 5 documents from the upstream libetonyek detection
suite, maintained by the LibreOffice / Document Liberation project.

Source revision: `6d19ce365f64a6217791a9438c85f4b1851ca7e0`.
Source directory: [libetonyek test data](https://github.com/LibreOffice/libetonyek/tree/6d19ce365f64a6217791a9438c85f4b1851ca7e0/src/test/data).
Upstream test: `src/test/EtonyekDocumentTest.cpp` identifies these as supported
Pages documents. The MPL 2.0 notice is retained in `COPYING`. These are offline
test fixtures, not runtime app resources. No Pages or LibreOffice is downloaded
or installed by tests; Office integration requires an already available backend.

| File | SHA-256 |
| --- | --- |
| `pages4-file.pages` | `793d9ece44e30c646a6b0c1d19e1feb314f94c2850e5da6d159326cd17991b4f` |
| `pages5-file.pages` | `b5de90dfa78077c62e1c88ddaa188e412ffa9dd31558e2774715733f9d58dfe7` |

Tests compare parsed exports, page count, and source preservation. Compatibility
with these examples does not promise exact layout fidelity for arbitrary Pages
versions, fonts, embedded media, or user documents.

The Pages 4 fixture is a blank one-page document. Its internal style/template
text is not document content; its embedded Quick Look PDF is also blank. The
Pages 5 fixture contains the hovercraft sentence in English, Czech, and Polish.
Tests require blank output for the former and retained Unicode text for the
latter rather than mistaking template text for a missing paragraph.
