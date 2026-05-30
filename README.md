# TechJam — Website

A modern, self-contained marketing site for **TechJam Ltd** — Microsoft Dynamics 365
Customer Engagement & Power Platform consultancy (Azure too), based in Derby, UK.

No build step. No framework. No dependencies. Just open it.

## View it
- **Quickest:** double-click `index.html`.
- **Recommended (for correct font/asset loading):** serve it locally:
  ```bash
  python3 -m http.server 8000
  # then open http://localhost:8000
  ```

## Structure
```
index.html        Single-page site (all sections)
404.html          Styled not-found page
css/theme.css     Design tokens — brand colours, type, spacing (THE swap point)
css/styles.css    Layout + components (reads only from theme.css)
js/main.js        Nav, mobile menu, scroll-reveal, count-up stats, active link, year
assets/           Logo, favicon (+ how to swap them — see assets/README.md)
TermsOfBusiness.pdf  Linked from the footer
robots.txt
```

## Customising
- **Brand colours:** edit `--brand-*` in `css/theme.css`. Everything re-themes automatically.
- **Logo:** replace `assets/logo.png` (an SVG is ideal). See `assets/README.md`.
- **Content:** all copy lives in `index.html`. Items marked *illustrative* (stats, case
  studies, testimonials) are placeholders — swap in real numbers and client stories.
- **Contact:** email is `hello@techjam.ltd`; phone is a `[ +44 phone ]` placeholder in the
  hero CTA and footer.

## Features
Animated gradient hero · glassmorphism cards · scroll-reveal & count-up animations ·
sticky frosted nav with active-section highlight · accessible mobile menu & FAQ accordion ·
fully responsive · honours `prefers-reduced-motion` · WCAG-minded (skip link, landmarks,
focus states, alt text).

## Deploy
It's static — drop the folder on any host (GitHub Pages, Netlify, Vercel, Azure Static Web
Apps, S3, …). No configuration required.
