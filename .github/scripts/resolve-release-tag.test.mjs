import assert from "node:assert/strict";
import test from "node:test";

import { compareSemVer, parseReleaseTag, resolveRelease } from "./resolve-release-tag.mjs";

test("SemVer ordering keeps prereleases before stable versions", () => {
  const ordered = ["v1.0.0", "v1.0.0-rc.10", "v1.0.0-rc.2", "v1.0.0-alpha"]
    .map(parseReleaseTag)
    .sort(compareSemVer)
    .map((version) => version.tag);
  assert.deepEqual(ordered, ["v1.0.0-alpha", "v1.0.0-rc.2", "v1.0.0-rc.10", "v1.0.0"]);
});

test("release resolution accepts the package tag on checked-out HEAD", () => {
  assert.deepEqual(resolveRelease({
    tags: ["v0.1.0-alpha.0", "v0.1.0-rc1"],
    packageVersion: "0.1.0-rc1",
    sourceSha: "release-sha",
    resolveTagSha: () => "release-sha",
  }), {
    tag: "v0.1.0-rc1",
    version: "0.1.0-rc1",
    sha: "release-sha",
  });
});

test("release resolution rejects a missing package tag", () => {
  assert.throws(() => resolveRelease({
    tags: ["v0.1.0-alpha.0"],
    packageVersion: "0.1.0-rc1",
    sourceSha: "release-sha",
    resolveTagSha: () => "release-sha",
  }), /Expected release tag v0\.1\.0-rc1 does not exist/);
});

test("release resolution rejects a package older than the latest tag", () => {
  assert.throws(() => resolveRelease({
    tags: ["v0.1.0-rc1", "v0.1.0"],
    packageVersion: "0.1.0-rc1",
    sourceSha: "release-sha",
    resolveTagSha: () => "release-sha",
  }), /older than release tag v0\.1\.0/);
});

test("release resolution rejects a tag outside checked-out HEAD", () => {
  assert.throws(() => resolveRelease({
    tags: ["v0.1.0-rc1"],
    packageVersion: "0.1.0-rc1",
    sourceSha: "source-sha",
    resolveTagSha: () => "tag-sha",
  }), /points to tag-sha, but checked-out HEAD is source-sha/);
});

test("release resolution rejects non-SemVer package versions", () => {
  assert.throws(() => resolveRelease({
    tags: ["v0.1.0"],
    packageVersion: "01.0.0",
    sourceSha: "release-sha",
    resolveTagSha: () => "release-sha",
  }), /Package version is not valid SemVer/);
});
