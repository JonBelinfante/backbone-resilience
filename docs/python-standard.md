# House Python standard

This page sets out the rules that every Python file in this repository follows, and how a program enforces them. It exists for the same reason as the Bash standard. A program checks the code, and taste does not. All services are written in Python. They are the payment service, the outbox relay, the consumers, the checker, the load generator, the failover controller and the router. The infrastructure scripts and the experiments stay in Bash.

## The standard in one sentence

Follow Python Enhancement Proposal (PEP) 8 for style, PEP 257 for docstrings and PEP 484 for type hints. Use the Google Python Style Guide as the tie-breaker where those are silent. Add the limits below. A program checks all of it, and **no rule can be waived**.

| Document | What it gives us |
|---|---|
| [PEP 8](https://peps.python.org/pep-0008/) | Layout, naming and imports. |
| [PEP 257](https://peps.python.org/pep-0257/) | What a docstring says and where it goes. |
| [PEP 484](https://peps.python.org/pep-0484/) | Type hints, which the type checker enforces. |
| [Google Python Style Guide](https://google.github.io/styleguide/pyguide.html) | One readable guide for everything that the PEPs leave open. Our docstrings use its Args and Returns sections. |

## What is enforced, and by what

The settings are in [pyproject.toml](../pyproject.toml). The tools run in a container at fixed versions, which are ruff, mypy and pytest. The [Dockerfile](../python-standard/Dockerfile) in `python-standard/` pins them, so every run gives the same answer.

| Rule | Limit or effect | Tool and rule family |
|---|---|---|
| Line length. | 100 columns. | Ruff, E. |
| Function size. | At most 40 statements, 10 branches and a complexity of 10. | Ruff, PLR and C90. |
| Parameters. | At most 4 for each function. | Ruff, PLR0913. |
| Docstrings. | Every public module, class and function has one, in Google style. | Ruff, D. |
| Types. | Every function is annotated, and mypy runs in strict mode. | Ruff, ANN, and mypy. |
| Naming. | Names follow PEP 8. | Ruff, N. |
| Logging, not printing. | `print` is forbidden, and log calls must be used correctly. | Ruff, T20, LOG and G. |
| Security. | No hard-coded secrets, no shell injection, and no `assert` for checks. | Ruff, S. |
| Errors. | No blind `except`, and no long messages written inline. | Ruff, BLE, TRY and EM. |
| Time. | No naive datetimes. | Ruff, DTZ. |
| Flags. | No boolean positional arguments. | Ruff, FBT. |
| Simpler code. | Simplifications are required, and commented-out code is forbidden. | Ruff, SIM, RET, PERF, PTH and ERA. |
| Tests. | Tests use pytest. The `assert` statement is allowed in test files only. | Pytest, with a per-file rule in the configuration. |

These rules are the Python counterparts of the Bash standard's limits. Those limits are 40-line functions, 4 parameters, 100 columns, no secrets on command lines, and no `echo` for logging.

## No waivers

A comment cannot switch a rule off. The comments `# noqa` and `# type: ignore`, and similar ones, are refused by [check-python.sh](../pg-replication/scripts/check-python.sh). Ruff itself would obey them. A file with `print("x")  # noqa: T201` passes ruff and fails the standard. If a rule is wrong for the repository, change [pyproject.toml](../pyproject.toml) for everyone, in the open, and give a reason.

## The checkers are checked

The folder [python-standard/fixtures](../python-standard/fixtures) holds two kinds of file. One **good** example, with its test, must pass every check. One small **bad** file for each rule must fail. The first line of each bad file names the tool and the rule that must catch it, for example `# expect: ruff PLR0913`. If a bad file is not caught, the check fails. A checker that has stopped catching something is worse than no checker.

The bad files cover these faults today.

- Too many parameters.
- A `print` call.
- A hard-coded secret.
- A blind `except`.
- A missing annotation.
- A missing docstring.
- Excess complexity.
- A naive datetime.
- A boolean positional argument.
- A type error, which mypy catches.
- A waiver comment.

## Running it

```bash
bash pg-replication/scripts/check-python.sh        # about 5 seconds once the tools image is built
bash pg-replication/scripts/run-all-checks.sh      # the Bash standard, the documents and Python, together
```

The first run builds the tools image, which needs network access to the Python package index. The code under check is the good example and everything under `services/`. Move the tool versions forward on purpose. Change them in the Dockerfile, run the check, and note the change in the commit.

## Rules for the Python written here

- One service is one folder under `services/`, with its tests next to it.
- A service is stateless and restartable. Its state lives in the database or the log.
- Configuration comes from the environment. The service reads it once at start-up and checks it there. Secrets come from files and never from arguments or logs.
- Every outward action is idempotent and carries its idempotency key. The actions are a database write, a payment and a message.
- Time and randomness are passed in. They are not read in the middle of logic, so tests are deterministic.
- The service's own folder records each library choice and the reason for it.

## Limits of this standard

- It is a standard for style, types and a few classes of mistake. It does not prove the code correct. The experiments and the independent checker do that.
- The rules are the ones that ruff and mypy implement at the pinned versions. A new version can add rules, which is why the versions are pinned.
- The Bash standard has a rule for each of its limits, but this standard leans on the tools' own rule families. Where a Bash rule has no counterpart yet, add one to the configuration or to the check script. A limit on file length is an example.
