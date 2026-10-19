# Optional local recipe research

No third-party recipes, recipe catalog or research snapshot is distributed. Dial In's own guidance is the original direction book in `data/recipes/original-book.json` and the setting rules and film-simulation profiles in `lib/plan/`; start with `npm run recipes -- knowledge --query "your scene"`.

The adapters in `lib/recipes/` read a research dataset you supply locally (`npm run recipes -- search --catalog DIRECTORY`), and the planner can read your own catalog named by `DIALIN_RECIPE_CATALOG`. Whether you may use a third party's recipes is between you and their author; code licensing does not cover it.
