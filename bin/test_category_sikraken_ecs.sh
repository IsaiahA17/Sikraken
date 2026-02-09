#!/usr/bin/env bash

echo "Starting Sikraken ECS run..."

echo "Waiting for benchmarks to be fully copied..."
while [ ! -f /shared/benchmarks/.complete ]; do
    sleep 1
done
echo "All benchmarks are present."

echo "Benchmarks content in /shared/benchmarks:"
ls /shared/benchmarks

CATEGORY="${CATEGORY:-chris}"
MODE="${MODE:-release}"
BUDGET="${BUDGET:-900}"
STACK_SIZE_GB="${STACK_SIZE_GB:-3}"

SHARD_INDEX="${SHARD_INDEX:-0}"
SHARD_COUNT="${SHARD_COUNT:-1}"

TIMESTAMP="${TIMESTAMP:-$(date -u +"%Y_%m_%d_%H_%M")}"

S3_BUCKET_NAME="ecs-benchmarks-output"
S3_BUCKET="${S3_BUCKET_NAME:?S3_BUCKET not set}"

SIKRAKEN_ROOT="/app/sikraken"
BENCHMARKS_SHARED="/shared/benchmarks"
OUTPUT_SHARED="/shared/output"

SIKRAKEN_SET_DIR="$SIKRAKEN_ROOT/categories"
SHARED_SET_DIR="$BENCHMARKS_SHARED"

run_sikraken() {
    # Safe defaults
    GCC_FLAG="${GCC_FLAG:-}"
    BENCH="${BENCH:-}"

    "$SIKRAKEN_ROOT/bin/sikraken.sh" \
        "$MODE" \
        "$GCC_FLAG" \
        budget["$BUDGET"] \
        --ss="$STACK_SIZE_GB" \
        "$BENCH"
}

copy_i_files_to_output() {
    echo "Copying .i files into benchmark output folders..."
    
    # Loop over all benchmark output folders
    for d in "$RUN_OUTPUT_DIR"/*/; do
        name=$(basename "$d")  # folder name matches benchmark basename
        # .i files are expected to be in SIKRAKEN_OUTPUT_PATH/$name/$name.i
        src_file="$SIKRAKEN_ROOT/sikraken_output/$name/$name.i"
        
        if [[ -f "$src_file" ]]; then
            cp "$src_file" "$d"
            echo "Copied $src_file → $d"
        else
            echo "WARNING: .i file not found: $src_file"
        fi
    done
}

CATEGORY_SET=""

if [[ -f "$SIKRAKEN_SET_DIR/$CATEGORY.set" ]]; then
    CATEGORY_SET="$SIKRAKEN_SET_DIR/$CATEGORY.set"
    echo "Using internal container .set file: $CATEGORY_SET"
elif [[ -f "$SHARED_SET_DIR/$CATEGORY.set" ]]; then
    CATEGORY_SET="$SHARED_SET_DIR/$CATEGORY.set"
    echo "Using shared benchmarks volume .set file: $CATEGORY_SET"
else
    echo "ERROR: .set file not found in either container or shared benchmarks: $CATEGORY.set"
    CATEGORY_SET=""
fi

if [[ -n "$CATEGORY_SET" ]]; then
    echo "Contents of chosen .set:"
    cat "$CATEGORY_SET"
else
    echo "WARNING: No .set file found. Continuing without benchmarks."
fi

EXCLUDE_SET=""
if [[ "$CATEGORY" == "ECA" ]]; then
    EXCLUDE_SET="$SIKRAKEN_SET_DIR/ECA-excludes.set"
    if [[ ! -f "$EXCLUDE_SET" ]]; then
        echo "WARNING: Exclude set $EXCLUDE_SET not found. Continuing without excludes."
        EXCLUDE_SET=""
    else
        echo "Using exclude set: $EXCLUDE_SET"
    fi
fi

#Initialising benchmarks array
ALL_BENCHMARKS=()

if [[ -n "$CATEGORY_SET" ]]; then
    #Add lines from set excluding comments, empty lines and sort then place into array
    mapfile -t PATTERNS < <(grep -v '^#' "$CATEGORY_SET" | grep -v '^$' | sort)

    for i in "${!PATTERNS[@]}"; do
        #Only taking indices from array that divide evenly with shard count
        if (( i % SHARD_COUNT != SHARD_INDEX )); then
            continue
        fi
        #Read data from .set
        pattern="${PATTERNS[$i]}"

        mapfile -t yml_files < <(find "$BENCHMARKS_SHARED" -type f -name "$(basename "$pattern")" | sort)

        if [[ ${#yml_files[@]} -eq 0 ]]; then
            echo "No files matching '$pattern' were found in $BENCHMARKS_SHARED."
            continue
        fi

        echo "Processing pattern from .set: '$pattern'"
        echo "Found .yml files:"
        printf '  %s\n' "${yml_files[@]}"

        for yml in "${yml_files[@]}"; do
            [[ ! -f "$yml" ]] && continue

            echo "Checking $yml for coverage property..."
            if ! grep -q 'coverage-branches\.prp' "$yml"; then
                echo "Skipped: missing coverage property"
                continue
            fi
            echo "Contains coverage property"

            benchmark_name=$(grep "^input_files:" "$yml" \
                             | sed -n "s/^[[:space:]]*input_files:[[:space:]]*['\"]\?\([^'\"].*[^'\"]\)['\"]\?/\1/p")

            if [[ -z "$benchmark_name" ]]; then
                echo "WARNING: no input_files specified in $yml"
                continue
            fi

            benchmark="$(dirname "$yml")/$benchmark_name"

            if [[ ! -f "$benchmark" ]]; then
                echo "WARNING: benchmark .c file missing for $yml"
                continue
            fi

            data_model=$(grep "data_model:" "$yml" \
                         | sed -n "s/^[[:space:]]*data_model:[[:space:]]*\(.*\)/\1/p")

            ALL_BENCHMARKS+=( "$benchmark|$data_model" )
        done
    done
fi

echo "Resolved ${#ALL_BENCHMARKS[@]} benchmarks for category $CATEGORY"

echo "TIMESTAMP: $TIMESTAMP"
echo "CATEGORY: $CATEGORY"
echo "SHARED_OUTPUT: $OUTPUT_SHARED"
RUN_OUTPUT_DIR="$OUTPUT_SHARED/$CATEGORY/$TIMESTAMP"
ls $RUN_OUTPUT_DIR
mkdir -p "$RUN_OUTPUT_DIR"

INDEX=0
TOTAL="${#ALL_BENCHMARKS[@]}"

for entry in "${ALL_BENCHMARKS[@]}"; do
    IFS="|" read -r BENCH DATA_MODEL <<< "$entry"

    NAME="$(basename "$BENCH" .c)"
    echo: "NAME: $NAME"
    OUTDIR="$RUN_OUTPUT_DIR/$NAME"
    echo "OUTDIR: $OUTDIR"
    mkdir -p "$OUTDIR"

    # Set GCC flags safely
    if [[ "$DATA_MODEL" == "ILP32" ]]; then
        GCC_FLAG="-m32"
    else
        GCC_FLAG="-m64"
    fi

    echo "[$INDEX/$TOTAL] Running Sikraken on $BENCH ($DATA_MODEL)"

    # Run Sikraken and log exit code, but do not fail script
    run_sikraken > "$OUTDIR/sikraken.log" 2>&1
    SIKRAKEN_EXIT=$?
    if [[ $SIKRAKEN_EXIT -ne 0 ]]; then
        echo "WARNING: Sikraken exited with code $SIKRAKEN_EXIT for $BENCH"
    else
        echo "Sikraken exited successfully for $BENCH"
    fi

    ((INDEX++))
done
copy_i_files_to_output

S3_PREFIX="s3://${S3_BUCKET}/${CATEGORY}/${TIMESTAMP}"

# Upload non-.i/.log files
ls $RUN_OUTPUT_DIR
aws s3 sync "$RUN_OUTPUT_DIR" "$S3_PREFIX" --exclude "*.i" --exclude "*.log"

# Upload .i and .log files with text/plain content-type
aws s3 sync "$RUN_OUTPUT_DIR" "$S3_PREFIX" \
    --exclude "*" \
    --include "*.i" \
    --include "*.log" \
    --content-type text/plain


echo "Sikraken ECS run completed"
echo "Container exiting cleanly"
sleep 5
exit 0
