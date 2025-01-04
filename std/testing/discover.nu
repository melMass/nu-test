use std/assert

const default_pattern = '**/{*[\-_]test,test[\-_]*}.nu'

export def list-suite-files [
    --glob: string = $default_pattern
    --matcher: string = ".*"
]: string -> list<string> {

    let path = $in
    list-files $path $glob
        | where ($it | path parse | get stem) like $matcher
}

def list-files [ path: string, pattern: string ]: nothing -> list<string> {
    if ($path | path type) == file {
        [$path]
    } else {
        cd $path
        glob $pattern
    }
}

export def list-test-suites [path: string]: nothing -> table<name: string, path: string, tests<table<name: string, type: string>>> {
    list-files $path $default_pattern
        | par-each { discover-suite $in }
}

def discover-suite [test_file: string]: nothing -> record<name: string, path: string, tests: table<name: string, type: string>> {
    let query = test-query $test_file
    let result = (^$nu.current-exe --no-config-file --commands $query)
        | complete

    if $result.exit_code == 0 {
        parse-suite $test_file ($result.stdout | from nuon)
    } else {
        error make { msg: $result.stderr }
    }
}

def parse-suite [test_file: string, tests: list<record<name: string, description: string>>]: nothing -> record<name: string, path: string, tests: table<name: string, type: string>> {
    {
        name: ($test_file | path parse | get stem)
        path: $test_file
        tests: ($tests | each { parse-test $in })
    }
}

def parse-test [test: record<name: string, description: string>]: nothing -> record<name: string, type: string> {
    let type = $test.description
        | parse --regex '.*\[([a-z-]+)\].*'
        | get capture0
        | first

    {
        name: $test.name,
        type: $type
    }
}

# Query any method with a specific tag in the description
def test-query [file: string]: nothing -> string {
    let query = "
        scope commands
            | where ( $it.type == 'custom' and $it.description =~ '\\[[a-z-]+\\]' )
            | each { |item| {
                name: $item.name
                description: $item.description
            } }
            | to nuon
    "
    $"source ($file); ($query)"
}
