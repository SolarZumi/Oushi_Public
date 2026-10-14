# Localization

`keys.json` lists every user-facing string: the key is the Simplified Chinese original (the source language),
with the English translation and a note on where it appears. `<lang>.json` holds one language's translations,
`{"key": "value"}`, or `{"key": {"one": …, "other": …}}` (plus `few` / `many` where the language needs them) for
strings with a count. `infoPlist` keys live in the same file under their own names.

`build_catalog.py` writes `App/Oushi/Resources/Localizable.xcstrings` and `InfoPlist.xcstrings` from these files,
writing each key's `note` as the catalog's comment, and checks that every placeholder in the original appears in
every translation. It also checks the code against `keys.json` both ways: every Chinese string literal in
`App/Oushi` must be a key (an interpolation counts as `%lld` or `%@`), and every key must be used; debug-only
wording that is not localized is listed under `notLocalized`. `build_catalog.py --check` only checks (the catalogs
must already be up to date) and exits non-zero on any problem; `Tools/check.sh` runs it with the tests and a build.
