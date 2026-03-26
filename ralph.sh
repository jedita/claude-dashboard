#!/bin/bash
set -e

MAX=${1:-10}
PROMPT="You are Ralph, an autonomous engineer implementing code.
    ## Context

    progress file: @/Users/tomas.jedlicka/Projects/claude-dashboard/progress.json
    plan file: @/Users/tomas.jedlicka/Projects/claude-dashboard/plan-implementation.md
    prd file: @/Users/tomas.jedlicka/Projects/claude-dashboard/prd-claude-code-terminal-dashboard.md
    test scenarios file: @/Users/tomas.jedlicka/Projects/claude-dashboard/test-scenarios.md
    working branch: master

    ## Steps

    1. Read the progress file to understand what has been already worked on and if all tasks are finished (done = true)
    2. Read prd file to understand general context
    3. Read plan file to see split of tasks to work on (slices)
    4. Pick up first task (slice from the plan) that has not been finished (not present in the progress file)
    5. Work on that ONE task only
    6. Read test scenarios file and run tests as indicated in the test scenarios in the particular slice
    6. Run tests/typecheck to verify code quality

    ## If Tests PASS

    - Update progress file: add an array with following properties:
      - name: the name of this task
      - decisions by ai: any decisions made by AI that were not documented in the plan file
      - diversions from the plan
      - aha moments: any initial expectations which were incorrect and were spotted during implmentation
      - test instructions: document how to test this step manually in the app by the user
      - done: true
    - Git commit on the branch (do not attribute claude as a co-author on commits). The commit message should contain identification of the step
    - Do not start to work on the new task
    - If ALL tasks from plan file are done, output: <promise>COMPLETE</promise>

    ## If Tests FAIL

    - Add what went wrong to the progress file under particular step (so next iteration can learn)
    - Do not start to work on the new task
"

echo "Starting Ralph - Max $MAX iterations"

for ((i=1; i<=$MAX; i++)); do

  echo "==========================================="
  echo "  Iteration $i of $MAX"
  echo "==========================================="

  tmpfile=$(mktemp)
  trap "rm -f $tmpfile" EXIT

    docker sandbox run claude \
      --print --model opus \
      $PROMPT \
      --output-format stream-json --verbose --include-partial-messages \
      | stdbuf -oL claude-stream-format \
      | stdbuf -oL sed $'s/$/\r/' \
      | tee "$tmpfile"

  if grep -q '<promise>COMPLETE</promise>' "$tmpfile"; then
      echo "==========================================="
      echo "  All tasks complete after $i iterations!"
      echo "==========================================="
      exit 0
  fi
done

echo "==========================================="
echo "  Reached max iterations ($MAX)"
echo "==========================================="
exit 1