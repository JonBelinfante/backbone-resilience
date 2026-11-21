# House Python standard

The rules every Python file in this repository follows, and how they are enforced. It exists for the same reason the Bash
standard does: so the code is checked by a program, not by taste. All services (payment service, outbox relay, consumers,
checker, load generator, failover controller, router) are Python; infrastructure scripts and experiments stay Bash.

## The standard in one sentence

Follow **PEP 8** (style), **PEP 257** (docstrings) and **PEP 484** (type hints), with the Google Python Style Guide as the
tie-breaker where those are silent, and the limits below. A program checks all of it and **no rule can be waived**.

| Document | What it gives us |
|---|---|
| [PEP 8](https://peps.python.org/pep-0008/) | Layout, naming, imports |
| [PEP 257](https://peps.python.org/pep-0257/) | What a docstring says and where |
| [PEP 484](https://peps.python.org/pep-0484/) | Type hints; the type checker enforces them |
| [Google Python Style Guide](https://google.github.io/styleguide/pyguide.html) | One readable guide for everything those leave open; our docstrings use its Args and Returns sections |

## What is enforced, and by what

The settings are in [pyproject.toml](../pyproject.toml). The tools run in a container at fixed versions (ruff, mypy, pytest;
see [python-standard/Dockerfile](../python-standard/Dockerfile)), so every run gives the same answer.

| Rule | Limit or effect | Tool and rule family |
|---|---|---|
| Line length | 100 columns | ruff, E |
| Function size | at most 40 statements, 10 branches, complexity 10 | ruff, PLR and C90 |
| Parameters | at most 4 per function | ruff, PLR0913 |
| Docstrings | every public module, class and function, Google style | ruff, D |
| Types | every function annotated; mypy in strict mode | ruff, ANN; mypy |
| Naming | PEP 8 names | ruff, N |
| Logging, not printing | no `print`; log calls used correctly | ruff, T20, LOG, G |
| No hard-coded secrets, no shell injection, no `assert` for checks | security rules | ruff, S |
| Errors | no blind `except`, no long messages inline | ruff, BLE, TRY, EM |
| Time | no naive datetimes | ruff, DTZ |
| Flags | no boolean positional arguments | ruff, FBT |
| Simpler code | simplifications, no commented-out code | ruff, SIM, RET, PERF, PTH, ERA |
| Tests | pytest; `assert` is allowed in test files only | pytest; per-file rule in the config |

These are the Python counterparts of the Bash standard's limits (40-line functions, 4 parameters, 100 columns, no secrets on
command lines, no `echo` for logging).

## No waivers

A comment cannot switch a rule off. `# noqa`, `# type: ignore` and similar are refused by
[check-python.sh](../pg-replication/scripts/check-python.sh), because ruff itself would obey them: a file with
`print("x")  # noqa: T201` passes ruff and fails the standard. If a rule is wrong for the repository, change
[pyproject.toml](../pyproject.toml) for everyone, in the open, with a reason.

## The checkers are checked

[python-standard/fixtures](../python-standard/fixtures) holds one **good** example, with its test, that must pass every check,
and one small **bad** file per rule that must fail. The first line of each bad file names the tool and rule that must catch it
(`# expect: ruff PLR0913`). If a bad file is not caught, the check fails: a checker that has stopped catching something is
worse than none. The bad files today cover too many parameters, `print`, a hard-coded secret, a blind `except`, a missing
annotation, a missing docstring, complexity, a naive datetime, a boolean positional argument, a type error (mypy) and a
waiver comment.

## Running it

```bash
bash pg-replication/scripts/check-python.sh        # about 5 seconds once the tools image is built
bash pg-replication/scripts/run-all-checks.sh      # the Bash standard, the documents and Python, together
```

The first run builds the tools image, which needs network access to the Python package index. The code to be checked is the
good example and, once it exists, everything under `services/`. Pull the tools versions forward deliberately: change them in
the Dockerfile, run the check, and note it in the commit.

## Rules for the Python written here

- One service is one folder under `services/`, with its tests next to it.
- A service is stateless and restartable; its state lives in the database or the log.
- Configuration comes from the environment, read once at start-up and checked there; secrets come from files, never from
  arguments or logs.
- Every outward action (a database write, a payment, a message) is idempotent and carries its idempotency key.
- Time and randomness are passed in, not read in the middle of logic, so tests are deterministic.
- Library choices are recorded in the service's own folder with the reason.

## Limits of this standard

- It is a standard for style, types and a few classes of mistake. It does not prove the code correct: the experiments and
  the independent checker do that.
- The rules are the ones ruff and mypy implement at the pinned versions; a new version can add rules, which is why the
  versions are pinned.
- The Bash standard has a rule for each of its limits; this one leans on the tools' own families. Where a Bash rule has no
  counterpart yet (for example, a limit on file length), add it to the configuration or to the check script.
