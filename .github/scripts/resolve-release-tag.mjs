import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const semverPattern = /^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$/;

export function parseReleaseTag(tag) {
  const match = semverPattern.exec(tag);
  if (!match) return null;

  const prerelease = match[4]?.split(".") ?? [];
  if (prerelease.some((identifier) => /^\d+$/.test(identifier) && identifier.length > 1 && identifier.startsWith("0"))) {
    return null;
  }

  return {
    tag,
    major: BigInt(match[1]),
    minor: BigInt(match[2]),
    patch: BigInt(match[3]),
    prerelease,
  };
}

export function compareSemVer(left, right) {
  for (const key of ["major", "minor", "patch"]) {
    if (left[key] < right[key]) return -1;
    if (left[key] > right[key]) return 1;
  }

  if (left.prerelease.length === 0 && right.prerelease.length > 0) return 1;
  if (right.prerelease.length === 0 && left.prerelease.length > 0) return -1;

  const length = Math.max(left.prerelease.length, right.prerelease.length);
  for (let index = 0; index < length; index += 1) {
    const leftIdentifier = left.prerelease[index];
    const rightIdentifier = right.prerelease[index];
    if (leftIdentifier === undefined) return -1;
    if (rightIdentifier === undefined) return 1;
    if (leftIdentifier === rightIdentifier) continue;

    const leftNumeric = /^\d+$/.test(leftIdentifier);
    const rightNumeric = /^\d+$/.test(rightIdentifier);
    if (leftNumeric && rightNumeric) {
      return BigInt(leftIdentifier) < BigInt(rightIdentifier) ? -1 : 1;
    }
    if (leftNumeric) return -1;
    if (rightNumeric) return 1;
    return leftIdentifier < rightIdentifier ? -1 : 1;
  }
  return 0;
}

export function resolveRelease({ tags, packageVersion, headSha, resolveTagSha }) {
  const expectedTag = `v${packageVersion}`;
  const expectedVersion = parseReleaseTag(expectedTag);
  if (!expectedVersion) {
    throw new Error(`Package version is not valid SemVer: ${packageVersion}`);
  }

  const releaseTags = tags.map(parseReleaseTag).filter(Boolean);
  if (releaseTags.length === 0) {
    throw new Error("No SemVer release tags matching v* were found");
  }
  if (!releaseTags.some((version) => version.tag === expectedTag)) {
    throw new Error(`Expected release tag ${expectedTag} does not exist`);
  }

  const newerTag = releaseTags.find((version) => compareSemVer(version, expectedVersion) > 0);
  if (newerTag) {
    throw new Error(`Package version ${packageVersion} is older than release tag ${newerTag.tag}`);
  }

  const tagSha = resolveTagSha(expectedTag);
  if (tagSha !== headSha) {
    throw new Error(`Release tag ${expectedTag} points to ${tagSha}, but main HEAD is ${headSha}`);
  }

  return { tag: expectedTag, version: packageVersion, sha: headSha };
}

function git(repositoryRoot, ...args) {
  return execFileSync("git", args, { cwd: repositoryRoot, encoding: "utf8" }).trim();
}

function main() {
  const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
  const packageJson = JSON.parse(readFileSync(resolve(repositoryRoot, "bindings/js/package.json"), "utf8"));
  const tags = git(repositoryRoot, "tag", "--list", "v*").split("\n").filter(Boolean);
  const release = resolveRelease({
    tags,
    packageVersion: packageJson.version,
    headSha: git(repositoryRoot, "rev-parse", "HEAD"),
    resolveTagSha: (tag) => git(repositoryRoot, "rev-list", "-n", "1", tag),
  });

  for (const [key, value] of Object.entries(release)) {
    process.stdout.write(`${key}=${value}\n`);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    main();
  } catch (error) {
    console.error(`Release validation failed: ${error instanceof Error ? error.message : String(error)}`);
    process.exitCode = 1;
  }
}
