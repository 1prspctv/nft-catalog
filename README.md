# nft-catalog

A browsable catalog of the NFTs held by 1prspctv.tez, with full-resolution viewing and set downloads.

Live page: https://1prspctv.github.io/nft-catalog/

## Apple TV app

`appletv/` holds a small tvOS app that plays the collection, or a set made in the catalog, as a full-screen slideshow.

- **Sets:** in the catalog, pick pieces and choose **Apple TV**. That opens a prefilled GitHub issue in this repo. The issue number is the set's code, and the app lists every open set issue opened by 1prspctv. Close the issue to remove the set. The **TV sets list** workflow copies the open sets to `sets.json` on the site whenever an issue changes, and the app reads that copy when GitHub's API limit gets in the way.
- **Build:** `.github/workflows/appletv.yml` compiles the app on a GitHub macOS runner on every push. Running it by hand with "Send to TestFlight" signs and uploads it, using the repository secrets `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` and `APPLE_TEAM_ID`.
- **WebM videos:** Apple TV can't play WebM, so `.github/workflows/webm-to-mp4.yml` makes MP4 copies under `media/`, listed in `media/index.json`.
- **Publishing:** GitHub Pages serves the `gh-pages` branch, which is kept identical to `main`. Push to both.
