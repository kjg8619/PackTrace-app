# Card catalogue snapshots

The `*.json` files in this folder are the card catalogues the app is built
with. They are generated from TCGdex data and are not tracked in Git in the
public repository; `catalog-manifest.json` at the repository root names each
one with its hashes. Install them with

    ./scripts/prepare-catalogs.sh <catalogue bundle or https URL>
    ./scripts/prepare-catalogs.sh --rebuild      # from TCGdex, slow

This file keeps the folder in Git (SwiftPM copies it as a resource); the app
only reads the `.json` files here.
