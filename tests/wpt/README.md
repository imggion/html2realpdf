# Selected Web Platform Tests

`src/wpt_subset_test.zig` adapts a deliberately small set of upstream Web
Platform Test scenarios into renderer-native geometry and pagination
assertions. The tests do not import a browser harness or reference screenshots;
they retain the relevant input condition and assert html2realpdf fragments or
PDF page counts directly.

Upstream revision: `74b2788f7705a172c25c0261b8ef0055bc61d3f2`

- [`css/css-flexbox/align-content-wrap-001.html`](https://github.com/web-platform-tests/wpt/blob/74b2788f7705a172c25c0261b8ef0055bc61d3f2/css/css-flexbox/align-content-wrap-001.html): a single wrapped Flex line is
  positioned by `align-content: center`.
- [`css/css-grid/grid-items/aspect-ratio-001.html`](https://github.com/web-platform-tests/wpt/blob/74b2788f7705a172c25c0261b8ef0055bc61d3f2/css/css-grid/grid-items/aspect-ratio-001.html): a definite Grid row and
  percentage block size transfer through `aspect-ratio` into intrinsic inline
  sizing.
- [`css/CSS2/pagination/page-break-before-001.xht`](https://github.com/web-platform-tests/wpt/blob/74b2788f7705a172c25c0261b8ef0055bc61d3f2/css/CSS2/pagination/page-break-before-001.xht): a later
  `page-break-before: auto` declaration cancels an earlier forced value.

Refresh these cases only intentionally: record the new upstream revision,
inspect the source diff, preserve the supported behavior being asserted, and
run both `make test-wpt` and `make test-release`.
