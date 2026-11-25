# tools

Not part of the add-on (not in the release zip). They regenerate `CrateData.lua`.

1. Save https://foreverdiff.com/waylaid-crates/ as HTML.
2. `python3 parse_foreverdiff.py <saved page>.html > crates.json`
3. `python3 gen_cratedata.py crates.json` (writes `../CrateData.lua`)

`crates.json` is the parsed list used for the current `CrateData.lua` (client build 1.60.1.71091, 2026-11-25).
Material IDs were cross-checked against QuestieDB 1.1.6 (Forever) item names; Merchant's Favor values are
community reports (Artisan is an estimate). See `gen_cratedata.py` for details.
