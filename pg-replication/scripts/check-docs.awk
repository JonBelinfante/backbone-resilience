# Helper for check-docs.sh. It is not run directly. Select the output with -v mode=NAME.
#   links        markdown links that are not web addresses: prints "DOC<TAB>TARGET"
#   definitions  shell function definitions: prints "FILE<TAB>NAME"
#   pairs        checks every backticked function-like name in the documents against the definitions
#                listed in the file named by -v definitions_file=PATH (written by definitions mode)

# Print a path in normal form: resolve . and .. and drop repeated slashes.
function norm(path,   parts, kept, n, i, k, out, prefix) {
  prefix = (substr(path, 1, 1) == "/") ? "/" : ""
  n = split(path, parts, "/")
  k = 0
  for (i = 1; i <= n; i++) {
    if (parts[i] == "" || parts[i] == ".") {
      continue
    }
    if (parts[i] == "..") {
      if (k > 0 && kept[k] != "..") {
        k--
      } else {
        kept[++k] = ".."
      }
    } else {
      kept[++k] = parts[i]
    }
  }
  out = ""
  for (i = 1; i <= k; i++) {
    out = out (i > 1 ? "/" : "") kept[i]
  }
  return prefix out
}

# Return the markdown link targets in a line that are not web addresses, separated by spaces.
function link_targets(line,   target, links) {
  links = ""
  while (match(line, /\]\([^)]*\)/)) {
    target = substr(line, RSTART + 2, RLENGTH - 3)
    line = substr(line, RSTART + RLENGTH)
    sub(/#.*/, "", target)
    if (target != "" && target !~ /^(https?:|mailto:)/) {
      links = links (links == "" ? "" : " ") target
    }
  }
  return links
}

BEGIN {
  if (mode == "pairs" && definitions_file != "") {
    while ((getline record < definitions_file) > 0) {
      split(record, field, "\t")
      if (field[2] != "") {
        defined_in[norm(field[1]) SUBSEP field[2]] = 1
        defined_any[field[2]] = 1
      }
    }
    close(definitions_file)
  }
}

mode == "links" {
  line = $0
  while (match(line, /\]\([^)]*\)/)) {
    target = substr(line, RSTART + 2, RLENGTH - 3)
    line = substr(line, RSTART + RLENGTH)
    sub(/#.*/, "", target)
    if (target != "" && target !~ /^(https?:|mailto:)/) {
      print FILENAME "\t" target
    }
  }
  next
}

mode == "definitions" && /^[a-z_][a-z0-9_]*(::[a-z_][a-z0-9_]*)?\(\) \{/ {
  name = $0
  sub(/\(\).*/, "", name)
  print FILENAME "\t" name
  next
}

mode == "pairs" {
  dir = FILENAME
  if (index(dir, "/") == 0) {
    dir = "."
  } else {
    sub(/\/[^\/]*$/, "", dir)
  }
  links = link_targets($0)
  line = $0
  while (match(line, /`[^`]+`/)) {
    name = substr(line, RSTART + 1, RLENGTH - 2)
    line = substr(line, RSTART + RLENGTH)
    if (name !~ /^[a-z_][a-z0-9_]*(::[a-z_][a-z0-9_]*)?$/ || name !~ /_|::/ || name ~ /^pg_/) {
      continue
    }
    if (!(name in defined_any)) {
      print "UNDEFINED " FILENAME ": `" name "` is not defined in any script"
      continue
    }
    if (links == "") {
      continue
    }
    found = 0
    n = split(links, targets, " ")
    for (i = 1; i <= n; i++) {
      if ((norm(dir "/" targets[i]) SUBSEP name) in defined_in) {
        found = 1
      }
    }
    if (!found) {
      print "MISMATCH " FILENAME ": `" name "` is not defined in the script this line links to (" links ")"
    }
  }
}
