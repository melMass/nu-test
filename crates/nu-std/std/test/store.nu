const res_table = "nu_test_results"
export def create [] {
  try {
    stor create --table-name $res_table --columns {
      suite: str
      test: str
      result: str
    }
    stor create --table-name nu_test_output --columns {
      suite: str
      test: str
      type: str
      line: str
    }
  } catch {|e|
    if ($e.json | from json | $in.labels?.0?.text | default "" | str starts-with $"table ($res_table) already exists") {
      delete
    }
  }
}

# We close the store so tests of this do not open the store multiple times
export def delete [] {
  stor delete --table-name $res_table
  stor delete --table-name nu_test_output
}

export def insert-result [row: record<suite: string,test: string,result: string>] {
  retry-on-lock "nu_test_results" {
    $row | stor insert --table-name $res_table
  }
}

export def insert-output [row: record<suite: string,test: string,type: string,lines: list<string>>] {
  retry-on-lock "nu_test_output" {
    $row
    | reject lines
    | merge { line: ($row.lines | str join "\n") }
    | stor insert --table-name nu_test_output
  }
}

# Parallel execution of tests causes contention on the SQLite database,
# which leads to failed inserts or missing data.
def retry-on-lock [table: string, operation: closure] {
  # We should eventually give up as an error flagging a bug is better than an infinite loop
  # Through stress testing, this number should be good for 500 tests with 50 lines of output/error
  let max_attempts = 20
  mut attempt = $max_attempts
  while $attempt > 0 {
    $attempt -= 1
    try {
      do $operation
      break
    } catch {|e|
      let reason = ($e.json | from json).labels?.0?.text?
      if $reason == $"database table is locked: ($table)" {
        # Retry
        continue
      } else {
        $e.raw # Rethrow anything else
      }
    }
  }

  if $attempt == 0 {
    error make { msg: $"Failed to insert into ($table) after ($max_attempts) attempts" }
  }
}

export def success []: nothing -> bool {
  let has_failures = stor open | query db "
        SELECT EXISTS (
            SELECT 1
            FROM nu_test_results
            WHERE result = 'FAIL'
        ) AS failures
    "
  | get failures.0 | into bool

  not $has_failures
}

export def query [color_scheme: closure]: nothing -> table<suite: string,test: string,result: string,output: string,error: string> {
  # SQL doesn't have backslash escapes so we use `char(10)`, being newline (\n)
  (
    stor open
    | query db "
                WITH
                    stream AS (
                        SELECT
                            suite,
                            test,
                            GROUP_CONCAT(
                                CASE
                                    WHEN type = 'error' THEN :error_prefix || line || :error_suffix
                                    ELSE line
                                END,
                                char(10)
                            ) AS output
                        FROM nu_test_output
                        GROUP BY suite, test
                    )

                SELECT
                    r.suite,
                    r.test,
                    r.result,
                    COALESCE(s.output, '') AS output

                FROM nu_test_results AS r

                LEFT JOIN stream AS s
                ON r.suite = s.suite AND r.test = s.test

                ORDER BY r.suite, r.test
            " --params {
      error_prefix: ({ prefix: "stderr" } | do $color_scheme)
      error_suffix: ({ suffix: "stderr" } | do $color_scheme)
    }
  )
}
