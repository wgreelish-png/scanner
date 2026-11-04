# Priced language choices and compact Card Research — build 62

Language choices now come from returned prices for the selected card. Market
research and editing use the exact product, printing and condition from the
existing pricing response. A valid zero market price is available; missing,
invalid or ambiguous SKU prices are not. Another product, printing or condition
cannot supply a language choice. No extra per-language requests are made, and
the normal pricing cache and refresh behavior remain in use.

Graded research uses its returned variants for the exact printing and selected
grader/grade, requiring an actual guide or research market value. When no grade
is selected, a priced grade for that grader can establish availability. Sales
counts and population alone do not establish a price. Hidden modes still do
not load merely to discover languages.

Unsupported languages are not offered as buttons or editor menu choices.
Existing saved language identities remain intact; choosing a different priced
language is explicit, and research never writes inventory. An empty result or
lookup failure cannot manufacture fallback languages. Cancelled or stale
responses cannot restore choices for an earlier selection.

Card Research follows the requested order: thumbnail beside price; card
details; printing choices; language when applicable; condition; TCGplayer link;
collapsed listing details; Market Activity. The price is displayed once, using
the current selection's result. Secondary listing information and provenance
stay in the disclosure. Graded access, inventory actions and accessibility
remain available. Scrolling remains possible when content or larger text needs
more room; ordinary card selection controls use less vertical space.

Implementation completes before validation. Parser/model regressions cover
exact identity, missing versus zero prices, duplicate SKUs, graded availability
and stale lookups. UI coverage checks the main order and collapsed listing
details. Xcode and physical iPhone layout/selection checks remain separate from
portable source checks; queued simulator jobs are not awaited after pushing.

Local checks passed: all 192 Swift source grammars, source/target membership,
build-62 revision metadata and whitespace. Seventeen new native cases and the
expanded layout UI scenario are authored. They require Xcode and have not run
in this Linux workspace. iPhone layout, language switching and CI remain
pending after push.
