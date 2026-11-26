# Documentation map

<!-- toc -->

- [I want to learn](#i-want-to-learn)
- [I want to look something up](#i-want-to-look-something-up)
- [I want to extend the work](#i-want-to-extend-the-work)
- [Background on the standards](#background-on-the-standards)

<!-- tocstop -->

This page lists every document by purpose. The root [README](../README.md) is the front page. Start with the path that matches what you want to do.

## I want to learn

| Document | What it gives you |
|---|---|
| [Primer: how PostgreSQL replication works](primer-postgresql-replication.md) | Six ideas that the tests rely on, with links to the official documentation. |
| [Glossary](glossary.md) | One definition for each term. |
| [Architecture](architecture.md) | A picture of the containers, volumes and parts. |
| [Learning path](learning-path.md) | Seven labs, each with a question, a command, an expected result and an exercise. |
| [Sample transcripts](transcripts/README.md) | Real output of four tests. |

## I want to look something up

| Document | What it gives you |
|---|---|
| [Failure modes](failure-modes.md) | Each fault, its effect, what handles it, the evidence and the remaining risk. |
| [Decision guide](decision-guide.md) | How to choose a replication mode, a lease time and the timeouts, and when to use backup. |
| [Capability catalogue](capability-catalogue.md) | One entry for each capability: problem, mechanism, test, result and limit. |
| [Capability register](../pg-replication/capability-register.md) | Every capability with its status, evidence, result and limit, and the open gaps. |
| [Evidence log](../pg-replication/evidence-log.md) | The commands, numbers and defects of each run. |
| [Robustness patterns](../pg-replication/docs/patterns/README.md) | The patterns that the scripts use to stay correct. |
| [Recovery report](../pg-replication/docs/recovery-report.md) | The measured loss and downtime. |
| [Secret rotation guide](../pg-replication/docs/secrets-rotation.md) | How to rotate database secrets with no failed write. |

## I want to extend the work

| Document | What it gives you |
|---|---|
| [Adding an experiment](adding-an-experiment.md) | The template and the steps. |
| [pg-replication README](../pg-replication/README.md) | Every script and library. |
| [Python standard](python-standard.md) | The rules that the Python code follows. |

## Background on the standards

| Document | What it gives you |
|---|---|
| [Proposal: one runtime library](proposal-runtime-library.md) | The reasoning behind the shared runtime library for the Bash standard. |
| [Change request to the Bash standard](change-request-bash-standard.md) | Changes that this project asked of the standard. |
