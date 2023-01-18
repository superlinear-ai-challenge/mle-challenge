#!/usr/bin/env bash
set -e

# Please do not edit this file!

ENDPOINT=https://5wlajyc8dl.execute-api.eu-west-1.amazonaws.com/prod/
ENV=hiring-challenge-env
HOST=localhost
PORT=9876
TEST_DATA=test.csv
TRAIN_DATA=train.csv
SUBMISSION=submission.json
RESULT=result.json
VERSION=2

# Formatting functions

function log() {
  local PURPLE='\033[0;35m'
  local NOCOLOR='\033[m'
  local BOLD='\033[1m'
  local NOBOLD='\033[0m'
  echo -e -n "${PURPLE}${BOLD}$1${NOBOLD}${NOCOLOR}"
}

# Environment

function activate_conda_environment() {
  if [ "$CONDA_DEFAULT_ENV" != $ENV ] && [ "$CONDA_DEFAULT_ENV" != 'base' ]; then
    log "Opening the Conda '$ENV' environment...\\n"
    conda activate $ENV
    log " --> Done!\\n\\n"
  fi
}

# Data

function clean_all() {
  if [[ -f $TRAIN_DATA ]]; then
    log "Removing previous $TRAIN_DATA...\\n"
    rm "$TRAIN_DATA"
    log " --> Done!\\n\\n"
  fi

  if [[ -f $TEST_DATA ]]; then
    log "Removing previous $TEST_DATA...\\n"
    rm "$TEST_DATA"
    log " --> Done!\\n\\n"
  fi

  if [[ -f $SUBMISSION ]]; then
    log "Removing previous $SUBMISSION...\\n"
    rm "$SUBMISSION"
    log " --> Done!\\n\\n"
  fi

  if [[ -f $RESULT ]]; then
    log "Removing previous $RESULT...\\n"
    rm "$RESULT"
    log " --> Done!\\n\\n"
  fi
}

function download_datasets() {
  if [[ ! -f $TRAIN_DATA ]] || [[ ! -f $TEST_DATA ]]; then
    log "Downloading datasets...\\n"
    {
      # Download testing data
      TEST_URL=$(
        curl \
          --silent \
          -request GET \
          --header 'accept: application/json' \
          --header "Content-Type: application/json" \
          ${ENDPOINT}test_url/$VERSION | tr -d '"'
      )
      curl \
        --fail \
        --silent \
        --request GET \
        "$TEST_URL" \
        >$TEST_DATA

      # Download training data
      TRAIN_URL=$(
        curl \
          --silent \
          -request GET \
          --header 'accept: application/json' \
          --header "Content-Type: application/json" \
          ${ENDPOINT}train_url/$VERSION | tr -d '"'
      )
      curl \
        --fail \
        --silent \
        --request GET \
        "$TRAIN_URL" \
        >$TRAIN_DATA
    } && {
      log " --> Done!\\n\\n"
    } || { # catch
      log " --> Unable to fetch datasets!\\n\\n"
      exit 1
    }
  fi
}

# API

function start_api() {
  log "Starting your API server in the background...\\n"
  uvicorn challenge:app --host 0.0.0.0 --port $PORT &
  API_PID=$!
  while ! lsof -Pi :$PORT -sTCP:LISTEN -t >/dev/null; do
    sleep 1
  done
  log " --> Done!\\n\\n"
}

function stop_api() {
  log "Shutting down the server...\\n"
  kill $API_PID
  sleep 5
  log " --> Done!\\n\\n"
}
trap stop_api SIGINT
trap stop_api SIGTERM

# Training

function train_model() {
  log "Training: POST $TRAIN_DATA to ${HOST}:${PORT}/genres/train...\\n"
  { # try
    curl \
      --fail \
      --request POST \
      --header "Content-Type: multipart/form-data" \
      --form "file=@$TRAIN_DATA;type=text/csv" \
      ${HOST}:${PORT}/genres/train
  } && {
    log " --> Done!\\n\\n"
  } || { # catch
    log " --> Training failed!\\n\\n"
    stop_api
    exit 1
  }
}

# Evaluation

function compute_predictions() {
  log "Predicting: POST $TEST_DATA to ${HOST}:${PORT}/genres/predict > $SUBMISSION...\\n"
  { # try
    curl \
      --fail \
      --silent \
      --request POST \
      --header "Content-Type: multipart/form-data" \
      --form "file=@$TEST_DATA;type=text/csv" \
      ${HOST}:${PORT}/genres/predict \
      >$SUBMISSION
  } && {
    log " --> Done!\\n\\n"
  } || { # catch
    log " --> Inference failed!\\n\\n"
    stop_api
    exit 1
  }
}

# Score calculations

function evaluate_results() {
  log "Evaluating the results...\\n"

  # Create the final result
  echo "{
  \"username\": \"$GIT_USER\",
  \"email\": \"$GIT_EMAIL\",
  \"code_quality\": {
    \"files\": [$FOLDER_SCORE, $FOLDER_ERRORS],
    \"flake8\": [$FLAKE8_SCORE, $FLAKE8_ERRORS],
    \"isort\": [$ISORT_SCORE, $ISORT_ERRORS],
    \"mypy\": [$MYPY_SCORE, $MYPY_ERRORS],
    \"pydocstyle\": [$PYDOC_SCORE, $PYDOC_ERRORS],
    \"sloc\": [$SLOC_SCORE, $SLOC]
  },
  \"predictions\": $(cat $SUBMISSION)
}" > $RESULT

  # Evaluate the result
  RESPONSE=$(
    curl \
      -i \
      --silent \
      --request POST \
      ${ENDPOINT}eval/${VERSION} \
      --header 'Accept: application/json' \
      --header 'Content-Type: application/json' \
      --data @$RESULT
  )
  if [ "$(echo "$RESPONSE" | grep HTTP | awk '{print $2}')" == "200" ]; then
    log " --> Done!\\n\\n"
    print_box "$(echo "$RESPONSE" | grep text)"
  else
    log " --> Failed! ($(echo "$RESPONSE" | grep detail | python -c "import sys, json; print(json.load(sys.stdin)['detail'])"))\\n\\n"
    exit 1
  fi
}

function normalize_score() {
  python -c "import math; print(max(min(math.exp($1 * $2 / max($3,1e-5) + $4),1),0))"
}

function print_box() {
  python - "$@" <<END
import sys, json
lines = json.loads(sys.argv[1])['text'].split('\n')
max_len = max(len(line) for line in lines)
lines = [f'║ {line.ljust(max_len)} ║' for line in lines]
lines = ['╔' + '═' * (max_len + 2) + '╗'] + lines + ['╚' + '═' * (max_len + 2) + '╝']
print('\n'.join(lines))
END
}

function get_folder_errors() {
  IN_FOLDER=$(find . -path './challenge/*.py' | wc -l)
  TOTAL=$(find . -name '*.py' | wc -l)
  echo $((TOTAL - IN_FOLDER))
}

function compute_code_quality_score() {
  log "Computing the code quality score... \\n"
  FOLDER_ERRORS=$(get_folder_errors)
  FLAKE8_ERRORS=$(flake8 challenge | wc -l)
  PYDOC_ERRORS=$(($(pydocstyle challenge | wc -l) / 2))
  MYPY_ERRORS=$(($(mypy challenge | wc -l) - 1))
  ISORT_ERRORS=$(isort challenge --diff | grep -E -o "\+import|\+from" | wc -l)
  SLOC=$(pygount challenge --suffix py | awk '{sum += $1} END {print sum}')
  FOLDER_SCORE=$((FOLDER_ERRORS == 0))
  FLAKE8_SCORE=$(normalize_score "$FLAKE8_ERRORS" -8 "$SLOC" 0) # exp(-8 * ERR / SLOC + 0)
  PYDOC_SCORE=$(normalize_score "$PYDOC_ERRORS" -8 "$SLOC" 0)   # exp(-8 * ERR / SLOC + 0)
  MYPY_SCORE=$(normalize_score "$MYPY_ERRORS" -8 "$SLOC" 0)     # exp(-8 * ERR / SLOC + 0)
  ISORT_SCORE=$(normalize_score "$ISORT_ERRORS" -8 "$SLOC" 0)   # exp(-8 * ERR / SLOC + 0)
  SLOC_SCORE=$(normalize_score "$SLOC" -1 800 0.125)            # exp(-1 * SLOC / 800 + 0.125)
  log " --> Done!\\n\\n"
}

# Communication

function get_git_username() {
  log "Fetching git information...\\n"
  if [ -z "$(git config user.name)" ]; then
    read -e -r -p "Please enter your git username: " GIT_USER
    git config --global user.name "$GIT_USER"
  else
    GIT_USER=$(git config user.name)
  fi
  if [ -z "$(git config user.email)" ]; then
    read -e -r -p "Please enter your git email address: " GIT_EMAIL
    git config --global user.email "$GIT_EMAIL"
  else
    GIT_EMAIL=$(git config user.email)
  fi

  if [ -z "$(git config user.name)" ] || [ -z "$(git config user.email)" ]; then
    log " --> Please fill in all the fields!\\n\\n"
  else
    log " --> Done!\\n\\n"
  fi
}

# Run the script
get_git_username
activate_conda_environment
clean_all
download_datasets
start_api
train_model
compute_predictions
stop_api
compute_code_quality_score
evaluate_results
