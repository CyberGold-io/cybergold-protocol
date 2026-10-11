#!/usr/bin/env node

import fs from "node:fs";
import process from "node:process";

const FEATURE_BRANCH = /^feature\/[a-z0-9](?:[a-z0-9._-]*[a-z0-9])?$/;
const COMMIT_SHA = /^[a-f0-9]{40}$/;

function fail(message) {
  throw new Error(message);
}

function required(value, name) {
  if (typeof value !== "string" || value.length === 0) fail(`${name} is required`);
  return value;
}

function requireCommitSha(value, name) {
  required(value, name);
  if (!COMMIT_SHA.test(value)) fail(`${name} must be a lowercase 40-character commit SHA`);
  return value;
}

function requireFeatureBranch(value) {
  if (!FEATURE_BRANCH.test(value)) {
    fail("pull requests into dev must come from a lowercase feature/<slug> branch");
  }
}

export function validatePullRequest({ repository, headRepository, baseRef, headRef }) {
  required(repository, "repository");
  required(baseRef, "base ref");
  required(headRef, "head ref");
  if (baseRef === "dev") {
    requireFeatureBranch(headRef);
    return;
  }
  if (baseRef === "main") {
    required(headRepository, "head repository");
    if (headRepository !== repository) fail("main accepts pull requests only from the canonical repository");
    if (headRef !== "dev") fail("main accepts pull requests only from dev");
    return;
  }
  fail("pull requests must target dev or main");
}

function matchingPullRequest(pr, { repository, refName, sha }) {
  if (!pr || typeof pr !== "object" || !pr.merged_at) return false;
  if (
    pr.base?.ref !== refName ||
    pr.base?.repo?.full_name !== repository ||
    pr.merge_commit_sha !== sha
  ) {
    return false;
  }
  return refName === "main"
    ? pr.head?.repo?.full_name === repository && pr.head?.ref === "dev"
    : FEATURE_BRANCH.test(pr.head?.ref ?? "");
}

function requireGitHubWebMergeProvenance(commit) {
  const gitCommit = commit.commit;
  const verification = gitCommit?.verification;
  const signature = verification?.signature;
  if (
    commit.committer?.login !== "web-flow" ||
    gitCommit?.committer?.name !== "GitHub" ||
    gitCommit?.committer?.email !== "noreply@github.com" ||
    verification?.verified !== true ||
    verification?.reason !== "valid" ||
    typeof signature !== "string" ||
    !signature.startsWith("-----BEGIN PGP SIGNATURE-----") ||
    !signature.trimEnd().endsWith("-----END PGP SIGNATURE-----")
  ) {
    fail("protected-branch publication requires a GitHub-web signed pull-request merge commit");
  }
}

export function validatePush({
  repository,
  refName,
  sha,
  beforeSha,
  forced,
  created,
  deleted,
  pullRequests,
  commit,
}) {
  required(repository, "repository");
  required(refName, "ref name");
  requireCommitSha(sha, "commit SHA");
  requireCommitSha(beforeSha, "prior branch SHA");
  if (refName !== "dev" && refName !== "main") fail("push admission applies only to dev and main");
  if (forced || created || deleted || /^0{40}$/.test(beforeSha)) {
    fail("protected-branch publication requires a non-forced update of an existing branch");
  }
  if (!Array.isArray(pullRequests)) fail("associated pull-request response must be an array");
  if (!commit || typeof commit !== "object" || commit.sha !== sha) {
    fail("pushed commit response does not match the triggering SHA");
  }
  requireGitHubWebMergeProvenance(commit);
  const parents = Array.isArray(commit.parents) ? commit.parents.map((parent) => parent.sha) : [];
  if (parents.length !== 2 || parents[0] !== beforeSha) {
    fail(`${refName} publication requires an ordered merge commit from the exact prior branch head`);
  }
  const matched = pullRequests.find(
    (pr) =>
      matchingPullRequest(pr, { repository, refName, sha }) && pr.head?.sha === parents[1],
  );
  if (!matched) fail(`push to ${refName} is not the merge result of an allowed pull request`);
}

function readJson(path, description) {
  return JSON.parse(fs.readFileSync(required(path, `${description} path`), "utf8"));
}

function booleanEnvInput(name) {
  const value = required(process.env[name], name);
  if (value === "true") return true;
  if (value === "false") return false;
  fail(`${name} must be true or false`);
}

function expectFailure(callback, description) {
  try {
    callback();
  } catch {
    return;
  }
  fail(`negative fixture unexpectedly passed: ${description}`);
}

function fixtureWebMerge(sha, parents) {
  return {
    sha,
    parents: parents.map((parent) => ({ sha: parent })),
    committer: { login: "web-flow" },
    commit: {
      committer: { name: "GitHub", email: "noreply@github.com" },
      verification: {
        verified: true,
        reason: "valid",
        signature: "-----BEGIN PGP SIGNATURE-----\nfixture\n-----END PGP SIGNATURE-----",
      },
    },
  };
}

function selfTest() {
  const repository = "CyberGold-io/example";
  const baseSha = "b".repeat(40);
  const featureSha = "f".repeat(40);
  const devSha = "d".repeat(40);
  const mainSha = "a".repeat(40);
  const featurePr = {
    merged_at: "2026-09-06T00:00:00Z",
    base: { ref: "dev", repo: { full_name: repository } },
    head: { ref: "feature/branch-policy", sha: featureSha, repo: { full_name: repository } },
    merge_commit_sha: devSha,
  };
  const promotionPr = {
    merged_at: "2026-09-06T00:00:00Z",
    base: { ref: "main", repo: { full_name: repository } },
    head: { ref: "dev", sha: devSha, repo: { full_name: repository } },
    merge_commit_sha: mainSha,
  };
  const forkFeaturePr = {
    ...featurePr,
    head: { ...featurePr.head, repo: { full_name: "contributor/example" } },
  };

  validatePullRequest({ repository, headRepository: repository, baseRef: "dev", headRef: "feature/branch-policy" });
  validatePullRequest({ repository, headRepository: "contributor/example", baseRef: "dev", headRef: "feature/branch-policy" });
  validatePullRequest({ repository, headRepository: repository, baseRef: "main", headRef: "dev" });
  for (const [description, input] of [
    ["malformed feature name", { repository, headRepository: repository, baseRef: "dev", headRef: "feature/Bad" }],
    ["malformed fork feature name", { repository, headRepository: "contributor/example", baseRef: "dev", headRef: "feature/Bad" }],
    ["fork dev-to-main", { repository, headRepository: "contributor/example", baseRef: "main", headRef: "dev" }],
    ["fork feature-to-main", { repository, headRepository: "contributor/example", baseRef: "main", headRef: "feature/branch-policy" }],
    ["feature-to-main", { repository, headRepository: repository, baseRef: "main", headRef: "feature/branch-policy" }],
  ]) {
    expectFailure(() => validatePullRequest(input), description);
  }

  validatePush({ repository, refName: "dev", sha: devSha, beforeSha: baseSha, forced: false, created: false, deleted: false, pullRequests: [featurePr], commit: fixtureWebMerge(devSha, [baseSha, featureSha]) });
  validatePush({ repository, refName: "dev", sha: devSha, beforeSha: baseSha, forced: false, created: false, deleted: false, pullRequests: [forkFeaturePr], commit: fixtureWebMerge(devSha, [baseSha, featureSha]) });
  validatePush({ repository, refName: "main", sha: mainSha, beforeSha: baseSha, forced: false, created: false, deleted: false, pullRequests: [promotionPr], commit: fixtureWebMerge(mainSha, [baseSha, devSha]) });
  expectFailure(() => validatePush({ repository, refName: "main", sha: mainSha, beforeSha: baseSha, forced: false, created: false, deleted: false, pullRequests: [{ ...promotionPr, head: { ...promotionPr.head, repo: { full_name: "contributor/example" } } }], commit: fixtureWebMerge(mainSha, [baseSha, devSha]) }), "fork promotion to main");
  expectFailure(() => validatePush({ repository, refName: "dev", sha: devSha, beforeSha: baseSha, forced: false, created: false, deleted: false, pullRequests: [{ ...forkFeaturePr, base: { ...forkFeaturePr.base, repo: { full_name: "contributor/example" } } }], commit: fixtureWebMerge(devSha, [baseSha, featureSha]) }), "merge into a different repository");
  expectFailure(() => validatePush({ repository, refName: "dev", sha: devSha, beforeSha: baseSha, forced: false, created: false, deleted: false, pullRequests: [{ ...forkFeaturePr, head: { ...forkFeaturePr.head, sha: "e".repeat(40) } }], commit: fixtureWebMerge(devSha, [baseSha, featureSha]) }), "fork head differs from the second merge parent");
  expectFailure(() => validatePush({ repository, refName: "dev", sha: devSha, beforeSha: baseSha, forced: false, created: false, deleted: false, pullRequests: [featurePr], commit: fixtureWebMerge(devSha, [baseSha]) }), "squash or rebase push");
  expectFailure(() => validatePush({ repository, refName: "dev", sha: devSha, beforeSha: baseSha, forced: false, created: false, deleted: false, pullRequests: [featurePr], commit: fixtureWebMerge(devSha, [featureSha, baseSha]) }), "reversed merge parents");
  expectFailure(() => validatePush({ repository, refName: "dev", sha: devSha, beforeSha: baseSha, forced: true, created: false, deleted: false, pullRequests: [featurePr], commit: fixtureWebMerge(devSha, [baseSha, featureSha]) }), "force push");
  expectFailure(() => validatePush({ repository, refName: "dev", sha: devSha, beforeSha: baseSha, forced: false, created: true, deleted: false, pullRequests: [featurePr], commit: fixtureWebMerge(devSha, [baseSha, featureSha]) }), "created branch");
  expectFailure(() => validatePush({ repository, refName: "dev", sha: devSha, beforeSha: baseSha, forced: false, created: false, deleted: true, pullRequests: [featurePr], commit: fixtureWebMerge(devSha, [baseSha, featureSha]) }), "deleted branch");
  expectFailure(() => validatePush({ repository, refName: "dev", sha: devSha, beforeSha: baseSha, forced: false, created: false, deleted: false, pullRequests: [{ ...featurePr, head: { ...featurePr.head, sha: "e".repeat(40) } }], commit: fixtureWebMerge(devSha, [baseSha, featureSha]) }), "unrelated pull-request head");
  const manualMerge = fixtureWebMerge(devSha, [baseSha, featureSha]);
  manualMerge.committer = { login: "writer" };
  expectFailure(() => validatePush({ repository, refName: "dev", sha: devSha, beforeSha: baseSha, forced: false, created: false, deleted: false, pullRequests: [featurePr], commit: manualMerge }), "unsigned manual merge");
  process.stdout.write("Branch-policy fixtures passed.\n");
}

try {
  if (process.argv[2] === "--self-test") selfTest();
  else if (process.argv[2] === "pull-request") {
    validatePullRequest({ repository: required(process.env.BRANCH_POLICY_REPOSITORY, "BRANCH_POLICY_REPOSITORY"), headRepository: process.env.BRANCH_POLICY_HEAD_REPOSITORY, baseRef: required(process.env.BRANCH_POLICY_BASE_REF, "BRANCH_POLICY_BASE_REF"), headRef: required(process.env.BRANCH_POLICY_HEAD_REF, "BRANCH_POLICY_HEAD_REF") });
    process.stdout.write("Pull-request branch policy passed.\n");
  } else if (process.argv[2] === "push") {
    validatePush({ repository: required(process.env.BRANCH_POLICY_REPOSITORY, "BRANCH_POLICY_REPOSITORY"), refName: required(process.env.BRANCH_POLICY_REF_NAME, "BRANCH_POLICY_REF_NAME"), sha: required(process.env.BRANCH_POLICY_SHA, "BRANCH_POLICY_SHA"), beforeSha: required(process.env.BRANCH_POLICY_BEFORE_SHA, "BRANCH_POLICY_BEFORE_SHA"), forced: booleanEnvInput("BRANCH_POLICY_FORCED"), created: booleanEnvInput("BRANCH_POLICY_CREATED"), deleted: booleanEnvInput("BRANCH_POLICY_DELETED"), pullRequests: readJson(process.env.BRANCH_POLICY_PULL_REQUESTS_FILE, "associated pull-request response"), commit: readJson(process.env.BRANCH_POLICY_COMMIT_FILE, "pushed-commit response") });
    process.stdout.write("Protected-branch push admission passed.\n");
  } else {
    fail("usage: check-branch-policy.mjs --self-test|pull-request|push");
  }
} catch (error) {
  process.stderr.write(`ERROR: ${error instanceof Error ? error.message : String(error)}\n`);
  process.exitCode = 1;
}
