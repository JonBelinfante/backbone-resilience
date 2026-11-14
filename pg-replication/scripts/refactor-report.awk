# Helper for refactor-report.sh. It is not run directly.
# Select what to do with -v mode=NAME:
#   functions   FILE...  one record per function: name, location, body (statements joined by ;)
#   show        FILE...  every definition of the function named by -v target=NAME, and how copies differ
#   header      FILE...  each script's purpose, usage line and the scripts it mentions
#   size        FILE...  one SIZE line per script (-v flagged=1 leaves out the ones that are fine)
#   identical | samename | similar   read the function records on standard input and group them
# Records use the separator character 034 (octal) between fields.

# The last two path components, for example scripts/verify.sh.
function short_name(path) {
  if (match(path, /[^\/]+\/[^\/]+$/)) {
    return substr(path, RSTART)
  }
  return path
}

# The file name without its directory.
function base_name(path) {
  sub(/^.*\//, "", path)
  return path
}

# Print the header summary of the file that was just read.
function flush_header() {
  if (current == "") {
    return
  }
  if (calls == "") {
    calls = " (none)"
  }
  printf "%s\n  purpose: %s\n  usage:   %s\n  mentions: %s\n", short_name(current), purpose, usage_line, calls
}

# Print the size line of the file that was just read.
function flush_size(   status) {
  if (current == "") {
    return
  }
  status = "ok"
  if (last_line > limit) {
    status = "OVER"
  } else if (last_line > warn) {
    status = "NEAR"
  }
  if (flagged && status == "ok") {
    return
  }
  printf "SIZE %-4s %4d %s\n", status, last_line, short_name(current)
}

# Forget the remembered set of statements.
function clear_set(set,   key) {
  for (key in set) {
    delete set[key]
  }
}

# A function definition has just ended: print its record, or keep it for the show report.
function finish_function() {
  sub(/;$/, "", body)
  if (mode == "functions" && !(name in skip)) {
    printf "%s%s%s:%d%s%s\n", name, SEP, short_name(FILENAME), start, SEP, body
  }
  if (mode == "show" && name == target) {
    shown++
    show_loc[shown] = short_name(FILENAME) ":" start
    show_raw[shown] = raw "\n}"
  }
}

BEGIN {
  SEP = "\034"
  if (mode == "identical" || mode == "samename" || mode == "similar") {
    FS = SEP
  }
  split(ignore, skip_list, " ")
  for (i in skip_list) {
    skip[skip_list[i]] = 1
  }
  name_count = split(names, name_list, " ")
}

mode == "functions" || mode == "show" {
  if (FNR == 1) {
    in_function = 0
  }
  if (!in_function && $0 ~ /^[a-z_0-9]+\(\) \{$/) {
    name = $0
    sub(/\(\) \{$/, "", name)
    start = FNR
    body = ""
    raw = $0
    in_function = 1
    next
  }
  if (in_function && $0 == "}") {
    finish_function()
    in_function = 0
    next
  }
  if (in_function) {
    raw = raw "\n" $0
    line = $0
    sub(/^[ \t]+/, "", line)
    if (line != "" && line !~ /^#/) {
      body = body line ";"
    }
  }
  next
}

mode == "header" {
  if (FNR == 1) {
    flush_header()
    current = FILENAME
    purpose = ""
    usage_line = ""
    calls = ""
  }
  if ($0 ~ /^# Purpose: / && purpose == "") {
    purpose = substr($0, 12)
  } else if ($0 ~ /^# Usage: / && usage_line == "") {
    usage_line = substr($0, 10)
  } else if ($0 !~ /^[ \t]*#/) {
    for (i = 1; i <= name_count; i++) {
      if (name_list[i] != base_name(current) && index($0, name_list[i]) > 0 && index(calls, name_list[i]) == 0) {
        calls = calls " " name_list[i]
      }
    }
  }
  next
}

mode == "size" {
  if (FNR == 1) {
    flush_size()
    current = FILENAME
  }
  last_line = FNR
  next
}

mode == "identical" || mode == "samename" || mode == "similar" {
  count++
  fn[count] = $1
  loc[count] = $2
  body_of[count] = $3
}

# Group functions whose bodies are identical, one line per group.
function report_identical(   i, key, members) {
  for (i = 1; i <= count; i++) {
    key = body_of[i]
    group_size[key]++
    members[key] = members[key] " " fn[i] "@" loc[i]
  }
  for (key in group_size) {
    if (group_size[key] > 1) {
      printf "IDENTICAL x%d%s\n", group_size[key], members[key]
    }
  }
}

# Group functions with the same name but more than one distinct body, one line per name.
function report_samename(   i, key, pair, members) {
  for (i = 1; i <= count; i++) {
    total[fn[i]]++
    members[fn[i]] = members[fn[i]] " " loc[i]
    pair = fn[i] SEP body_of[i]
    if (!(pair in seen_pair)) {
      seen_pair[pair] = 1
      distinct[fn[i]]++
    }
  }
  for (key in total) {
    if (distinct[key] > 1) {
      printf "DRIFTED %s x%d bodies=%d%s\n", key, total[key], distinct[key], members[key]
    }
  }
}

# Pair up functions that share at least threshold percent of their statements.
function report_similar(   a, b, j, parts_a, parts_b, set_b, count_a, count_b, shared, longest, percent) {
  for (a = 1; a <= count; a++) {
    count_a = split(body_of[a], parts_a, ";")
    for (b = a + 1; b <= count; b++) {
      if (body_of[a] == body_of[b]) {
        continue
      }
      count_b = split(body_of[b], parts_b, ";")
      clear_set(set_b)
      for (j = 1; j <= count_b; j++) {
        set_b[parts_b[j]] = 1
      }
      shared = 0
      for (j = 1; j <= count_a; j++) {
        if (parts_a[j] in set_b) {
          shared++
        }
      }
      longest = (count_a > count_b) ? count_a : count_b
      percent = int(shared * 100 / longest)
      if (longest >= minimum && percent >= threshold) {
        printf "SIMILAR %d%% %s@%s %s@%s\n", percent, fn[a], loc[a], fn[b], loc[b]
      }
    }
  }
}

# Print the first definition in full, then for each other copy whether and how it differs.
function report_show(   i, j, first_count, other_count, first_lines, other_lines, in_first, in_other) {
  if (shown == 0) {
    printf "no function named %s\n", target
    return
  }
  printf "%s: %d definitions\n--- %s\n%s\n", target, shown, show_loc[1], show_raw[1]
  first_count = split(show_raw[1], first_lines, "\n")
  for (i = 2; i <= shown; i++) {
    if (show_raw[i] == show_raw[1]) {
      printf "--- %s identical to the first\n", show_loc[i]
      continue
    }
    printf "--- %s differs from the first (+ only here, - only in the first):\n", show_loc[i]
    other_count = split(show_raw[i], other_lines, "\n")
    clear_set(in_first)
    clear_set(in_other)
    for (j = 1; j <= first_count; j++) {
      in_first[first_lines[j]] = 1
    }
    for (j = 1; j <= other_count; j++) {
      in_other[other_lines[j]] = 1
    }
    for (j = 1; j <= other_count; j++) {
      if (!(other_lines[j] in in_first)) {
        printf "+ %s\n", other_lines[j]
      }
    }
    for (j = 1; j <= first_count; j++) {
      if (!(first_lines[j] in in_other)) {
        printf "- %s\n", first_lines[j]
      }
    }
    if (other_count == first_count && length(in_first) == length(in_other)) {
      print "  (same set of lines: only the order or repeats differ)"
    }
  }
}

END {
  if (mode == "header") {
    flush_header()
  } else if (mode == "size") {
    flush_size()
  } else if (mode == "identical") {
    report_identical()
  } else if (mode == "samename") {
    report_samename()
  } else if (mode == "similar") {
    report_similar()
  } else if (mode == "show") {
    report_show()
  }
}
